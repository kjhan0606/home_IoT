import json

import pytest
import responses

from homehub import capabilities as cap
from homehub import linking
from homehub.adapters.samsung_tv import SamsungTVAdapter
from homehub.discovery import engine
from homehub.manager import DeviceManager
from homehub.models import Device, DiscoveredHost

from .fixtures import (ST_BASE, ST_TV, ST_TV_STATUS, ST_WASHER, st_washer_status)

TV_MAC = "aa:bb:cc:dd:ee:ff"


@pytest.fixture
def lan_tv(monkeypatch):
    """A Samsung TV on the LAN, claimed by samsung_local (no real network)."""
    host = DiscoveredHost(ip="192.168.0.20", mac=TV_MAC, vendor="Samsung Electronics",
                          sources=["arp", "mdns"], mdns_services=["_samsungmsf._tcp.local."],
                          open_ports=[8001, 8002])
    passive = DiscoveredHost(ip="192.168.0.30", mac="11:22:33:44:55:66", hostname="Washer",
                             vendor="Samsung Electronics", sources=["arp"])
    monkeypatch.setattr(engine, "scan", lambda **kw: [host, passive])
    monkeypatch.setattr(SamsungTVAdapter, "_rest_info", lambda self, ip: {
        "device": {"name": "[TV] Samsung 8 Series (55)", "modelName": "UN55KS8500"}})
    return host


def _st_mocks(rs):
    rs.get(f"{ST_BASE}/devices", json={"items": [ST_TV, ST_WASHER]})
    rs.get(f"{ST_BASE}/devices/tv-1/status", json=ST_TV_STATUS)
    rs.get(f"{ST_BASE}/devices/washer-1/status", json=st_washer_status())


def test_no_tokens_scan_is_lan_only(lan_tv):
    with responses.RequestsMock() as rs:          # any HTTP call would fail the test
        m = DeviceManager()
        devs = m.scan()
        assert len(rs.calls) == 0
    assert {d.adapter for d in devs} == {"samsung_local", "unknown"}
    assert m.cloud_errors == {}


@responses.activate
def test_tv_deduplicated_lan_primary_with_cloud_fallback(lan_tv, monkeypatch):
    monkeypatch.setenv("SMARTTHINGS_TOKEN", "pat")
    _st_mocks(responses)
    m = DeviceManager()
    devs = m.scan()
    tvs = [d for d in devs if d.kind == "tv"]
    assert len(tvs) == 1
    tv = tvs[0]
    assert tv.adapter == "samsung_local" and tv.id == f"samsung_local:{TV_MAC}"
    assert tv.meta["fallback"]["id"] == "smartthings:tv-1"
    # Cloud adds absolute volume + playback and fills unknown power state.
    assert "setLevel" in tv.capabilities[cap.VOLUME].actions
    assert cap.MEDIA_PLAYBACK in tv.capabilities
    assert tv.capabilities[cap.POWER].state["switch"] == "on"
    # Cloud id resolves to the merged device.
    assert m.get("smartthings:tv-1").id == tv.id
    # Passive LAN host "Washer" replaced by the cloud washer (keeps ip/mac).
    washer = m.get("smartthings:washer-1")
    assert washer.ip == "192.168.0.30" and washer.adapter == "smartthings"
    assert m.get("host:11:22:33:44:55:66").id == washer.id
    assert len(devs) == 2


@responses.activate
def test_command_routing_local_first_then_cloud(lan_tv, monkeypatch):
    monkeypatch.setenv("SMARTTHINGS_TOKEN", "pat")
    _st_mocks(responses)
    responses.post(f"{ST_BASE}/devices/tv-1/commands", json={"results": []})
    sent = []
    monkeypatch.setattr(SamsungTVAdapter, "_send_key", lambda self, d, k: sent.append(k))
    m = DeviceManager()
    m.scan()
    tv_id = f"samsung_local:{TV_MAC}"

    # local path works -> local used, no cloud call
    r = m.execute(tv_id, cap.VOLUME, "volumeDown", {})
    assert r["method"] == "ws" and sent == ["KEY_VOLDOWN"]
    assert not [c for c in responses.calls if c.request.method == "POST"]

    # action only the cloud supports -> cloud
    r = m.execute(tv_id, cap.VOLUME, "setLevel", {"level": 20})
    assert r["via"] == "smartthings"
    body = json.loads(responses.calls[-1].request.body)["commands"][0]
    assert body["command"] == "setVolume" and body["arguments"] == [20]

    # local transport failure -> cloud fallback
    def boom(self, d, k):
        raise RuntimeError("TV websocket unreachable")
    monkeypatch.setattr(SamsungTVAdapter, "_send_key", boom)
    r = m.execute(tv_id, cap.VOLUME, "volumeUp", {})
    assert r["via"] == "smartthings" and "unreachable" in r["primaryError"]

    # validation errors are NOT masked by fallback
    with pytest.raises(ValueError):
        m.execute(tv_id, cap.CHANNEL, "setChannel", {"channel": "abc"})


@responses.activate
def test_cloud_failure_keeps_previous_devices(lan_tv, monkeypatch):
    monkeypatch.setenv("SMARTTHINGS_TOKEN", "pat")
    _st_mocks(responses)
    m = DeviceManager()
    m.scan()
    responses.replace(responses.GET, f"{ST_BASE}/devices", status=500, json={"error": "boom"})
    devs = m.scan(lan=False)
    assert "smartthings" in m.cloud_errors
    assert m.get("smartthings:washer-1") is not None
    assert len(devs) == 2


@responses.activate
def test_token_removed_drops_cloud_devices(lan_tv, monkeypatch):
    monkeypatch.setenv("SMARTTHINGS_TOKEN", "pat")
    _st_mocks(responses)
    m = DeviceManager()
    m.scan()
    monkeypatch.delenv("SMARTTHINGS_TOKEN")
    devs = m.scan(lan=False)
    assert all(d.adapter != "smartthings" for d in devs)
    assert "fallback" not in m.get(f"samsung_local:{TV_MAC}").meta


def _dev(id_, kind="tv", vendor="Samsung", controllable=True, name="Living TV", model=None, mac=None, adapter="x"):
    return Device(id=id_, name=name, adapter=adapter, kind=kind, vendor=vendor, mac=mac,
                  controllable=controllable, meta={"model": model} if model else {})


def _cloud(id_, name="Living TV", model=None, mac=None, kind="tv", brand="Samsung Electronics"):
    return Device(id=id_, name=name, adapter="smartthings", kind=kind, controllable=True,
                  meta={"match": {"brand": brand, "model": model, "name": name, "mac": mac}})


def test_linking_rules():
    lan = _dev("lan1", model="UN55KS8500")
    assert linking.same_device(lan, _cloud("c", name="Other", model="UN55KS8500FXZA"))   # model prefix
    assert linking.same_device(lan, _cloud("c", name="[TV] Living TV"))                  # name
    assert not linking.same_device(lan, _cloud("c", name="Bedroom", model="QN65Q80"))
    assert not linking.same_device(lan, _cloud("c", brand="LG"))                          # brand mismatch
    assert not linking.same_device(lan, _cloud("c", kind="washer"))
    assert linking.same_device(_dev("p", controllable=False, mac="AA-BB-CC-00-11-22", name="x"),
                               _cloud("c", name="y", mac="aa:bb:cc:00:11:22"))            # MAC wins


def test_ambiguous_match_not_linked():
    lan = [_dev("a", model="UN55KS8500"), _dev("b", model="UN55KS8500", name="Other")]
    merged, aliases = linking.merge(lan, [_cloud("c", name="Nope", model="UN55KS8500")])
    assert len(merged) == 3 and aliases == {}
    assert set(next(d for d in merged if d.id == "c").meta["linkAmbiguous"]) == {"a", "b"}
