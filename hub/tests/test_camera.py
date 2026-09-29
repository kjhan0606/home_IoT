"""IP camera support: ONVIF (mocked SOAP), RTSP/MJPEG helpers, camera store, API."""
import base64
import hashlib
import io
import os
import re
import stat

import pytest
import responses
from fastapi.testclient import TestClient

from homehub import capabilities as cap
from homehub import mappings, server
from homehub.adapters import demo, registry
from homehub.adapters.camera import CameraAdapter
from homehub.camera import media, onvif
from homehub.camera import store as camstore
from homehub.discovery import engine
from homehub.manager import DeviceManager
from homehub.models import DiscoveredHost

DEV = "http://192.168.0.50/onvif/device_service"
MEDIA = "http://192.168.0.50/onvif/media_service"
PTZ = "http://192.168.0.50/onvif/ptz_service"

ENV = ('<?xml version="1.0"?><s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" '
       'xmlns:tt="http://www.onvif.org/ver10/schema" xmlns:tds="http://www.onvif.org/ver10/device/wsdl" '
       'xmlns:trt="http://www.onvif.org/ver10/media/wsdl" xmlns:tptz="http://www.onvif.org/ver20/ptz/wsdl">'
       '<s:Body>{}</s:Body></s:Envelope>')

TIME = ENV.format("<tds:GetSystemDateAndTimeResponse><tds:SystemDateAndTime><tt:UTCDateTime>"
                  "<tt:Time><tt:Hour>1</tt:Hour><tt:Minute>2</tt:Minute><tt:Second>3</tt:Second></tt:Time>"
                  "<tt:Date><tt:Year>2026</tt:Year><tt:Month>9</tt:Month><tt:Day>29</tt:Day></tt:Date>"
                  "</tt:UTCDateTime></tds:SystemDateAndTime></tds:GetSystemDateAndTimeResponse>")
INFO = ENV.format("<tds:GetDeviceInformationResponse><tds:Manufacturer>ExampleCo</tds:Manufacturer>"
                  "<tds:Model>EC-100</tds:Model><tds:FirmwareVersion>1.2</tds:FirmwareVersion>"
                  "<tds:SerialNumber>SN1</tds:SerialNumber><tds:HardwareId>HW</tds:HardwareId>"
                  "</tds:GetDeviceInformationResponse>")


def caps_xml(ptz=True):
    return ENV.format(
        "<tds:GetCapabilitiesResponse><tds:Capabilities>"
        f"<tt:Media><tt:XAddr>{MEDIA}</tt:XAddr></tt:Media>"
        + (f"<tt:PTZ><tt:XAddr>{PTZ}</tt:XAddr></tt:PTZ>" if ptz else "")
        + "</tds:Capabilities></tds:GetCapabilitiesResponse>")


def profiles_xml(ptz=True):
    def prof(tok, name, w, h, enc):
        return (f'<trt:Profiles token="{tok}" fixed="true"><tt:Name>{name}</tt:Name>'
                f"<tt:VideoEncoderConfiguration><tt:Encoding>{enc}</tt:Encoding>"
                f"<tt:Resolution><tt:Width>{w}</tt:Width><tt:Height>{h}</tt:Height></tt:Resolution>"
                "</tt:VideoEncoderConfiguration>"
                + ("<tt:PTZConfiguration token='p'><tt:Name>ptz</tt:Name></tt:PTZConfiguration>" if ptz else "")
                + "</trt:Profiles>")
    return ENV.format("<trt:GetProfilesResponse>" + prof("prof_main", "mainStream", 1920, 1080, "H264")
                      + prof("prof_sub", "subStream", 640, 360, "JPEG") + "</trt:GetProfilesResponse>")


STREAM_URI = ENV.format("<trt:GetStreamUriResponse><trt:MediaUri><tt:Uri>rtsp://192.168.0.50:554/live/main"
                        "</tt:Uri></trt:MediaUri></trt:GetStreamUriResponse>")
SNAP_URI = ENV.format("<trt:GetSnapshotUriResponse><trt:MediaUri><tt:Uri>http://192.168.0.50/snap.jpg"
                      "</tt:Uri></trt:MediaUri></trt:GetSnapshotUriResponse>")
PRESETS = ENV.format('<tptz:GetPresetsResponse><tptz:Preset token="1"><tt:Name>Door</tt:Name></tptz:Preset>'
                     '<tptz:Preset token="2"><tt:Name>Sofa</tt:Name></tptz:Preset></tptz:GetPresetsResponse>')
FAULT_AUTH = ('<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"><s:Body><s:Fault><s:Code>'
              '<s:Value>s:Sender</s:Value><s:Subcode><s:Value>ter:NotAuthorized</s:Value></s:Subcode></s:Code>'
              '<s:Reason><s:Text>Sender not Authorized</s:Text></s:Reason></s:Fault></s:Body></s:Envelope>')
FAULT_NOSNAP = FAULT_AUTH.replace('ter:NotAuthorized', 'ter:ActionNotSupported').replace(
    'Sender not Authorized', 'Optional Action Not Implemented')
JPEG = b"\xff\xd8\xff\xe0FAKEJPEG\xff\xd9"


def mock_onvif(ptz=True, snapshot=True):
    """Route SOAP bodies to canned answers by operation name."""
    def cb(request):
        body = request.body.decode() if isinstance(request.body, bytes) else request.body
        for op, xml in [("GetSystemDateAndTime", TIME), ("GetDeviceInformation", INFO),
                        ("GetCapabilities", caps_xml(ptz)), ("GetProfiles", profiles_xml(ptz)),
                        ("GetStreamUri", STREAM_URI), ("GetPresets", PRESETS),
                        ("ContinuousMove", ENV.format("<tptz:ContinuousMoveResponse/>")),
                        ("GotoPreset", ENV.format("<tptz:GotoPresetResponse/>")),
                        ("Stop", ENV.format("<tptz:StopResponse/>"))]:
            if f"<tds:{op}" in body or f"<trt:{op}" in body or f"<tptz:{op}" in body:
                return 200, {"Content-Type": "application/soap+xml"}, xml
        if "GetSnapshotUri" in body:
            return (200, {}, SNAP_URI) if snapshot else (400, {}, FAULT_NOSNAP)
        return 400, {}, "unknown"
    responses.add_callback(responses.POST, DEV, callback=cb)
    responses.add_callback(responses.POST, MEDIA, callback=cb)
    responses.add_callback(responses.POST, PTZ, callback=cb)


@pytest.fixture
def adapter(monkeypatch):
    a = CameraAdapter()
    monkeypatch.setattr(registry, "CAMERA_ADAPTER", a)
    monkeypatch.setattr(registry, "_BY_ID", {**registry._BY_ID, "camera": a})
    monkeypatch.setattr(registry, "CLOUD_ADAPTERS", [x for x in registry.CLOUD_ADAPTERS if x.id != "camera"] + [a])
    monkeypatch.setattr("homehub.adapters.camera._tcp_ok", lambda *a, **k: True)
    return a


@pytest.fixture
def client(adapter, monkeypatch):
    monkeypatch.setattr(server, "manager", DeviceManager())
    monkeypatch.setattr(server, "_register_bonjour", lambda: (None, None))
    with TestClient(server.app) as c:
        yield c


# --- canonical model ---------------------------------------------------------------
def test_capabilities_and_mappings():
    assert cap.VIDEO_STREAM in cap.CANONICAL and cap.PTZ in cap.CANONICAL
    cap.validate_action(cap.PTZ, "move")
    with pytest.raises(ValueError):
        cap.validate_action(cap.PTZ, "explode")
    assert mappings.describe(cap.VIDEO_STREAM)["matter"]["id"] == "0x551"
    assert cap.CANONICAL[cap.PTZ].ui_hint == "ptz-pad"
    assert cap.CANONICAL[cap.VIDEO_STREAM].ui_hint == "camera-view"


# --- ONVIF client --------------------------------------------------------------------
@responses.activate
def test_onvif_full_flow_and_digest_auth():
    mock_onvif()
    c = onvif.OnvifClient(DEV, "admin", "s3cret")
    assert c.device_information()["Model"] == "EC-100"
    c.discover_services()
    assert c.media_url == MEDIA and c.ptz_url == PTZ
    profs = c.profiles()
    assert [p["token"] for p in profs] == ["prof_main", "prof_sub"]
    assert (profs[0]["width"], profs[0]["height"], profs[0]["codec"], profs[0]["ptz"]) == (1920, 1080, "H264", True)
    assert c.stream_uri("prof_main") == "rtsp://192.168.0.50:554/live/main"
    assert c.snapshot_uri("prof_main") == "http://192.168.0.50/snap.jpg"
    assert [p["token"] for p in c.ptz_presets("prof_main")] == ["1", "2"]

    # WS-Security digest is really Base64(SHA1(nonce + created + password)); no plain password on the wire.
    body = responses.calls[-1].request.body.decode()
    assert "s3cret" not in body
    nonce = base64.b64decode(re.search(r"<Nonce[^>]*>([^<]+)</Nonce>", body).group(1))
    created = re.search(r"<Created[^>]*>([^<]+)</Created>", body).group(1)
    digest = re.search(r"<Password[^>]*>([^<]+)</Password>", body).group(1)
    assert digest == base64.b64encode(hashlib.sha1(nonce + created.encode() + b"s3cret").digest()).decode()
    # camera clock (2026-09-29 01:02:03Z) is used for <Created>, not ours
    assert c._clock_offset.total_seconds() != 0


@responses.activate
def test_onvif_ptz_requests_and_errors():
    mock_onvif()
    c = onvif.OnvifClient(DEV, "admin", "pw")
    c.discover_services()
    c.ptz_move("prof_main", 0.5, -0.25, 0, 1.0)
    body = responses.calls[-1].request.body.decode()
    assert 'x="0.500" y="-0.250"' in body and "PT1.0S" in body and "<tt:Zoom" not in body
    c.ptz_stop("prof_main")
    assert "<tptz:Stop>" in responses.calls[-1].request.body.decode()
    c.ptz_goto_preset("prof_main", "2")
    assert "<tptz:PresetToken>2</tptz:PresetToken>" in responses.calls[-1].request.body.decode()


@responses.activate
def test_onvif_auth_fault_and_unreachable():
    responses.post(DEV, body=FAULT_AUTH, status=400)
    with pytest.raises(onvif.OnvifAuthError):
        onvif.OnvifClient(DEV, "admin", "bad").device_information()
    responses.reset()
    responses.post(DEV, status=401)
    with pytest.raises(onvif.OnvifAuthError):
        onvif.OnvifClient(DEV, "admin", "bad").device_information()
    responses.reset()
    with pytest.raises(onvif.OnvifError, match="cannot reach camera"):
        onvif.OnvifClient(DEV, "a", "b").device_information()


def test_ptz_absent_raises():
    c = onvif.OnvifClient(DEV)
    with pytest.raises(onvif.OnvifError, match="no ONVIF PTZ"):
        c.ptz_stop("x")


def test_normalize_device_url():
    assert onvif.normalize_device_url("192.168.0.9") == "http://192.168.0.9/onvif/device_service"
    assert onvif.normalize_device_url("192.168.0.9:8080") == "http://192.168.0.9:8080/onvif/device_service"
    assert onvif.normalize_device_url("http://h/custom") == "http://h/custom"
    with pytest.raises(ValueError):
        onvif.normalize_device_url("http://")


PROBE_MATCH = b"""<?xml version="1.0"?><e:Envelope xmlns:e="http://www.w3.org/2003/05/soap-envelope"
xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery"><e:Body><d:ProbeMatches><d:ProbeMatch>
<d:Types>dn:NetworkVideoTransmitter</d:Types>
<d:Scopes>onvif://www.onvif.org/name/Front%20Door onvif://www.onvif.org/hardware/EC-100 onvif://www.onvif.org/location/country/kr</d:Scopes>
<d:XAddrs>http://192.168.0.50:8080/onvif/device_service http://10.0.0.5/onvif/device_service</d:XAddrs>
</d:ProbeMatch></d:ProbeMatches></e:Body></e:Envelope>"""


def test_ws_discovery_parsing():
    m = onvif.parse_probe_matches(PROBE_MATCH, "192.168.0.50")[0]
    assert m["host"] == "192.168.0.50" and m["name"] == "Front Door" and m["hardware"] == "EC-100"
    assert m["onvifUrl"] == "http://192.168.0.50:8080/onvif/device_service"
    assert onvif.parse_probe_matches(b"not xml") == []
    assert b"NetworkVideoTransmitter" in onvif._probe_message()


def test_discovery_engine_merges_onvif_and_rtsp_port(monkeypatch):
    monkeypatch.setattr(engine, "subnet_prefix", lambda: "192.168.0")
    monkeypatch.setattr(engine, "ping_sweep", lambda p: [])
    monkeypatch.setattr(engine, "arp_table", lambda p: {"192.168.0.51": "aa:bb:cc:00:00:01"})
    monkeypatch.setattr(engine.mdns, "browse", lambda t: {})
    monkeypatch.setattr(engine.ssdp, "discover", lambda t: {})
    monkeypatch.setattr(engine.oui, "lookup", lambda m, online=True: None)
    monkeypatch.setattr(engine, "lan_ip", lambda: "192.168.0.2")
    monkeypatch.setattr(engine.onvif, "ws_discover", lambda t, ip: onvif.parse_probe_matches(PROBE_MATCH, "192.168.0.50"))
    monkeypatch.setattr(engine, "_probe_ports", lambda ip: [554] if ip == "192.168.0.51" else [])
    assert 554 in engine.PROBE_PORTS and 8554 in engine.PROBE_PORTS
    hosts = {h.ip: h for h in engine.scan(online_oui=False)}
    assert "onvif" in hosts["192.168.0.50"].sources and hosts["192.168.0.50"].hostname == "Front Door"
    devs = {d.ip: d for d in registry.build_devices(list(hosts.values()))}
    assert devs["192.168.0.50"].kind == "camera" and devs["192.168.0.50"].meta["onvifUrl"].endswith("device_service")
    assert devs["192.168.0.51"].kind == "camera"          # RTSP port alone -> weak "camera" hint
    assert not devs["192.168.0.50"].controllable          # still passive until the user adds it


def test_rtsp_port_does_not_override_known_vendor():
    h = DiscoveredHost(ip="1.1.1.1", vendor="Samsung", open_ports=[554])
    assert registry.infer_kind(h) == "tv"


# --- media helpers ---------------------------------------------------------------------
def test_credential_helpers():
    clean, u, p = media.split_credentials("rtsp://admin:p%40ss@192.168.0.5:554/s1?x=1")
    assert (clean, u, p) == ("rtsp://192.168.0.5:554/s1?x=1", "admin", "p@ss")
    assert media.with_credentials(clean, "admin", "p@ss") == "rtsp://admin:p%40ss@192.168.0.5:554/s1?x=1"
    assert media.split_credentials("rtsp://h/x") == ("rtsp://h/x", None, None)
    assert "hunter2" not in media.redact("failed rtsp://bob:hunter2@10.0.0.1/x")
    assert media.default_port("rtsp://h/x") == 554


def test_mjpeg_frame_splitter_handles_chunk_boundaries():
    f1, f2 = b"\xff\xd8AAAA\xff\xd9", b"\xff\xd8BB\xff\xd9"
    stream = b"--frame\r\nContent-Type: image/jpeg\r\n\r\n" + f1 + b"\r\n--frame\r\n\r\n" + f2 + b"\r\n"
    chunks = iter([stream[i:i + 7] for i in range(0, len(stream), 7)])
    assert list(media.iter_jpeg_frames(chunks)) == [f1, f2]
    assert media.multipart_frame(f1).startswith(b"--frame\r\nContent-Type: image/jpeg")


@responses.activate
def test_http_get_answers_digest_and_basic():
    url = "http://192.168.0.60/snap.jpg"
    seen = []

    def cb(request):
        seen.append(request.headers.get("Authorization", ""))
        if not seen[-1]:
            return 401, {"WWW-Authenticate": 'Basic realm="cam"'}, b""
        return 200, {}, JPEG
    responses.add_callback(responses.GET, url, callback=cb)
    assert media.fetch_jpeg(url, "admin", "pw") == JPEG
    assert seen[-1].startswith("Basic ")
    responses.reset()
    responses.get(url, status=401)
    with pytest.raises(media.MediaError, match="user name or password"):
        media.fetch_jpeg(url, "admin", "bad")
    responses.reset()
    responses.get(url, body=b"<html>", status=200)
    with pytest.raises(media.MediaError, match="not a JPEG"):
        media.fetch_jpeg(url, None, None)


def test_rtsp_snapshot_without_ffmpeg(monkeypatch):
    monkeypatch.setattr(media, "ffmpeg_path", lambda: None)
    with pytest.raises(media.MediaError, match="ffmpeg is not installed"):
        media.rtsp_snapshot("rtsp://h/x")


def test_rtsp_snapshot_runs_ffmpeg_and_redacts_errors(monkeypatch):
    monkeypatch.setattr(media, "ffmpeg_path", lambda: "/usr/bin/ffmpeg")

    class R:
        def __init__(self, rc, out, err):
            self.returncode, self.stdout, self.stderr = rc, out, err
    calls = []
    monkeypatch.setattr(media.subprocess, "run", lambda cmd, **k: (calls.append(cmd), R(0, JPEG, b""))[1])
    assert media.rtsp_snapshot("rtsp://a:b@h/x") == JPEG
    assert "-rtsp_transport" in calls[0] and "tcp" in calls[0]
    monkeypatch.setattr(media.subprocess, "run", lambda cmd, **k: R(1, b"", b"error rtsp://a:hunter2@h/x 401"))
    with pytest.raises(media.MediaError) as e:
        media.rtsp_snapshot("rtsp://a:hunter2@h/x")
    assert "hunter2" not in str(e.value)


# --- store + adapter ----------------------------------------------------------------------
def test_store_is_0600_and_redacts():
    camstore.put({"id": "camera:1", "name": "x", "password": "pw", "username": "u"})
    path = camstore.secret_store.path_for("cameras")
    assert stat.S_IMODE(os.stat(path).st_mode) == 0o600
    assert stat.S_IMODE(os.stat(path.parent).st_mode) == 0o700
    assert "password" not in camstore.redacted(camstore.get("camera:1"))
    assert camstore.redacted(camstore.get("camera:1"))["hasPassword"] is True
    assert camstore.remove("camera:1") and not camstore.remove("camera:1")


@responses.activate
def test_add_onvif_camera_builds_brand_neutral_device(adapter):
    mock_onvif()
    dev = adapter.add_camera({"protocol": "onvif", "address": "192.168.0.50", "name": "현관",
                              "username": "admin", "password": "pw"})
    assert dev.kind == "camera" and dev.adapter == "camera" and dev.vendor == "ExampleCo"
    vs = dev.capabilities[cap.VIDEO_STREAM]
    assert vs.state["rtspUrl"] == "rtsp://192.168.0.50:554/live/main"
    assert vs.state["selectedProfile"] == "prof_main"          # H.264 preferred
    assert vs.state["snapshotAvailable"] and vs.actions == ["selectProfile"]
    ptz = dev.capabilities[cap.PTZ]
    assert set(ptz.actions) == {"move", "stop", "gotoPreset"} and ptz.state["presets"][0] == {"token": "1", "name": "Door"}
    # secrets never in the Device
    assert "pw" not in str(dev.to_dict()) and "admin" not in str(dev.to_dict())
    saved = camstore.get(dev.id)
    assert saved["password"] == "pw" and "@" not in saved["rtspUrl"]


@responses.activate
def test_add_onvif_without_ptz_or_snapshot(adapter):
    mock_onvif(ptz=False, snapshot=False)
    dev = adapter.add_camera({"protocol": "onvif", "address": "192.168.0.50", "username": "a", "password": "b"})
    assert cap.PTZ not in dev.capabilities
    assert camstore.get(dev.id)["snapshotUrl"] is None


@responses.activate
def test_add_onvif_wrong_password(adapter):
    responses.post(DEV, body=FAULT_AUTH, status=400)
    with pytest.raises(onvif.OnvifAuthError):
        adapter.add_camera({"protocol": "onvif", "address": "192.168.0.50", "username": "a", "password": "x"})
    assert camstore.list_cameras() == []


def test_add_manual_rtsp_moves_embedded_credentials(adapter):
    dev = adapter.add_camera({"protocol": "rtsp", "url": "rtsp://admin:pw@192.168.0.70:554/stream1",
                              "name": "마당", "verify": False})
    cfg = camstore.get(dev.id)
    assert cfg["rtspUrl"] == "rtsp://192.168.0.70:554/stream1" and cfg["username"] == "admin" and cfg["password"] == "pw"
    assert cap.PTZ not in dev.capabilities and dev.capabilities[cap.VIDEO_STREAM].actions == []
    with pytest.raises(ValueError):
        adapter.add_camera({"protocol": "rtsp", "url": "http://x", "verify": False})
    with pytest.raises(ValueError):
        adapter.add_camera({"protocol": "zigbee"})


def test_add_manual_rtsp_verifies_connection(adapter, monkeypatch):
    monkeypatch.setattr("homehub.adapters.camera._tcp_ok", lambda *a, **k: False)
    with pytest.raises(media.MediaError, match="cannot connect"):
        adapter.add_camera({"protocol": "rtsp", "url": "rtsp://192.168.0.70/x"})


@responses.activate
def test_add_http_mjpeg_and_snapshot(adapter):
    responses.get("http://192.168.0.80/video", body=b"--f\r\n" + JPEG, headers={"Content-Type": "multipart/x-mixed-replace;boundary=f"})
    responses.get("http://192.168.0.81/snap", body=JPEG, headers={"Content-Type": "image/jpeg"})
    responses.get("http://192.168.0.82/x", body=b"hi", headers={"Content-Type": "text/html"})
    a = adapter.add_camera({"protocol": "http", "url": "http://192.168.0.80/video"})
    b = adapter.add_camera({"protocol": "http", "url": "http://192.168.0.81/snap"})
    assert camstore.get(a.id)["mjpegUrl"] and camstore.get(b.id)["snapshotUrl"]
    with pytest.raises(media.MediaError, match="neither"):
        adapter.add_camera({"protocol": "http", "url": "http://192.168.0.82/x"})
    assert adapter.snapshot(a) == JPEG                      # first frame of the MJPEG stream
    assert adapter.snapshot(b) == JPEG
    assert next(iter(adapter.mjpeg_frames(a))) == JPEG


@responses.activate
def test_execute_ptz_and_profile_select(adapter, monkeypatch):
    mock_onvif()
    dev = adapter.add_camera({"protocol": "onvif", "address": "192.168.0.50", "username": "a", "password": "b"})
    monkeypatch.setattr(adapter, "_schedule_stop", lambda *a, **k: None)
    assert adapter.execute(dev, "ptz", "move", {"pan": 0.5, "durationMs": 300})["ok"]
    assert "ContinuousMove" in responses.calls[-1].request.body.decode()
    for bad in ({"pan": 2}, {"pan": "x"}, {}, {"pan": 0.1, "durationMs": 99999}):
        with pytest.raises(ValueError):
            adapter.execute(dev, "ptz", "move", bad)
    adapter.execute(dev, "ptz", "gotoPreset", {"preset": "2"})
    with pytest.raises(ValueError, match="unknown preset"):
        adapter.execute(dev, "ptz", "gotoPreset", {"preset": "99"})
    adapter.execute(dev, "videoStream", "selectProfile", {"profile": "prof_sub"})
    assert camstore.get(dev.id)["selectedProfile"] == "prof_sub"
    with pytest.raises(ValueError, match="unknown profile"):
        adapter.execute(dev, "videoStream", "selectProfile", {"profile": "nope"})
    with pytest.raises(ValueError):
        adapter.execute(dev, "ptz", "explode", {})


def test_ptz_not_available_for_manual_rtsp(adapter):
    dev = adapter.add_camera({"protocol": "rtsp", "url": "rtsp://192.168.0.70/x", "verify": False})
    with pytest.raises(ValueError, match="without ONVIF"):
        adapter.execute(dev, "ptz", "stop", {})


def test_list_devices_reports_reachability(adapter, monkeypatch):
    adapter.add_camera({"protocol": "rtsp", "url": "rtsp://192.168.0.70/x", "verify": False})
    assert adapter.list_devices()[0].reachable is True
    monkeypatch.setattr("homehub.adapters.camera._tcp_ok", lambda *a, **k: False)
    assert adapter.list_devices()[0].reachable is False


# --- HTTP API --------------------------------------------------------------------------------
@responses.activate
def test_api_add_snapshot_stream_delete(client, monkeypatch):
    mock_onvif()
    responses.get("http://192.168.0.50/snap.jpg", body=JPEG, headers={"Content-Type": "image/jpeg"})
    r = client.post("/cameras", json={"protocol": "onvif", "address": "192.168.0.50", "name": "현관",
                                      "username": "admin", "password": "pw"})
    assert r.status_code == 200, r.text
    cid = r.json()["device"]["id"]
    assert "pw" not in r.text
    assert [d["id"] for d in client.get("/devices").json()["devices"]] == [cid]
    assert client.get("/cameras").json()["cameras"][0]["hasPassword"] is True
    assert "password" not in client.get("/cameras").json()["cameras"][0]
    snap = client.get(f"/devices/{cid}/snapshot.jpg")
    assert snap.status_code == 200 and snap.content == JPEG and snap.headers["content-type"] == "image/jpeg"
    info = client.get(f"/devices/{cid}/stream").json()
    assert info["rtspUrl"] == "rtsp://192.168.0.50:554/live/main" and "@" not in info["rtspUrl"]
    assert info["mjpegUrl"].endswith("stream.mjpeg")
    monkeypatch.setattr(server.registry.CAMERA_ADAPTER, "_schedule_stop", lambda *a, **k: None)
    m = client.post(f"/devices/{cid}/commands", json={"capability": "ptz", "action": "move", "params": {"pan": 1}})
    assert m.status_code == 200
    assert client.post(f"/devices/{cid}/commands",
                       json={"capability": "ptz", "action": "move", "params": {"pan": 5}}).status_code == 400
    assert client.delete(f"/cameras/{cid}").status_code == 200
    assert client.get("/devices").json()["devices"] == []
    assert client.delete(f"/cameras/{cid}").status_code == 404


@responses.activate
def test_api_wrong_camera_password_is_403_not_401(client):
    responses.post(DEV, body=FAULT_AUTH, status=400)
    r = client.post("/cameras", json={"protocol": "onvif", "address": "192.168.0.50", "username": "a", "password": "x"})
    assert r.status_code == 403 and "password" in r.json()["detail"]


def test_api_bad_input_and_non_camera(client):
    assert client.post("/cameras", json={"protocol": "rtsp", "url": "ftp://x"}).status_code == 400
    assert client.get("/devices/nope/snapshot.jpg").status_code == 404
    assert client.get("/devices/nope/stream.mjpeg").status_code == 404


def test_camera_endpoints_need_hub_token(client, monkeypatch):
    monkeypatch.setattr(server.config, "API_TOKEN", "secret")
    for method, path in [("get", "/cameras"), ("get", "/cameras/discover"), ("post", "/cameras"),
                         ("get", "/devices/x/snapshot.jpg"), ("get", "/devices/x/stream.mjpeg"),
                         ("get", "/devices/x/stream"), ("delete", "/cameras/x")]:
        kw = {"json": {"protocol": "rtsp"}} if method == "post" else {}
        assert getattr(client, method)(path, **kw).status_code == 401, path
    assert client.get("/cameras", headers={"X-HomeHub-Token": "secret"}).status_code == 200


def test_api_discover(client, monkeypatch):
    monkeypatch.setattr(server.cam_onvif, "ws_discover", lambda t, ip: onvif.parse_probe_matches(PROBE_MATCH, "192.168.0.50"))
    cams = client.get("/cameras/discover").json()["cameras"]
    assert cams[0]["host"] == "192.168.0.50" and cams[0]["added"] is False


def test_integrations_listing_unchanged(client):
    assert "camera" not in client.get("/integrations").json()["integrations"]
    assert "camera" not in client.get("/health").json()["integrations"]


# --- demo cameras --------------------------------------------------------------------------------
@pytest.fixture
def demo_hub(monkeypatch):
    monkeypatch.setenv(demo.ENV, "1")
    a = demo.DemoAdapter()
    monkeypatch.setattr(registry, "CLOUD_ADAPTERS", [*registry.CLOUD_ADAPTERS, a])
    monkeypatch.setattr(registry, "_BY_ID", {**registry._BY_ID, "demo": a})
    monkeypatch.setattr(server, "manager", server.DeviceManager())
    with TestClient(server.app) as c:
        yield c


def test_demo_cameras_snapshot_ptz_and_stream(demo_hub):
    devs = {d["id"]: d for d in demo_hub.get("/devices").json()["devices"]}
    assert devs["demo:cam-living"]["kind"] == "camera" and "ptz" in devs["demo:cam-living"]["capabilities"]
    assert "ptz" not in devs["demo:cam-door"]["capabilities"]
    a = demo_hub.get("/devices/demo:cam-living/snapshot.jpg")
    assert a.status_code == 200 and a.content[:2] == b"\xff\xd8"
    from PIL import Image
    assert Image.open(io.BytesIO(a.content)).size == (demo.CAM_W, demo.CAM_H)
    demo_hub.post("/devices/demo:cam-living/commands", json={"capability": "ptz", "action": "move", "params": {"pan": 1}})
    b = demo_hub.get("/devices/demo:cam-living/snapshot.jpg")
    assert b.content != a.content                              # PTZ visibly moves the picture
    assert demo_hub.post("/devices/demo:cam-living/commands",
                         json={"capability": "ptz", "action": "gotoPreset", "params": {"preset": "9"}}).status_code == 400
    assert demo_hub.post("/devices/demo:cam-living/commands",
                         json={"capability": "ptz", "action": "move", "params": {"pan": 9}}).status_code == 400
    assert demo_hub.get("/devices/demo:cam-door/stream").json()["mjpegUrl"].endswith("stream.mjpeg")
    assert demo_hub.get("/devices/demo:tv/snapshot.jpg").status_code == 404


def test_mjpeg_relay_wraps_frames_in_multipart(demo_hub, monkeypatch):
    """Starlette's TestClient cannot consume an endless stream, so feed a finite one."""
    monkeypatch.setattr(server.manager, "camera_frames", lambda i, fps=5: iter([JPEG, JPEG, JPEG]))
    r = demo_hub.get("/devices/demo:cam-door/stream.mjpeg")
    assert r.status_code == 200 and r.headers["content-type"].startswith("multipart/x-mixed-replace")
    assert r.content.count(b"--frame\r\nContent-Type: image/jpeg") == 3 and JPEG in r.content
    assert server._streams_open == 0                       # counter released when the stream ends


def test_demo_frame_generator_is_endless_and_valid(demo_hub):
    a = server.registry.get_adapter("demo")
    dev = server.manager.get("demo:cam-door")
    gen = a.mjpeg_frames(dev, fps=100)
    assert next(gen)[:2] == b"\xff\xd8" and next(gen)[:2] == b"\xff\xd8"
    gen.close()
