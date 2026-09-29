"""Dev-only demo adapter: sample devices with in-memory state (EXAMPLE DATA).

Enabled only when ``HOMEHUB_FAKE_DEVICES=1``. It is a normal ``CloudAdapter``
(lists devices, executes canonical commands, renders a vacuum map), so the app
and API exercise exactly the same code paths as with real integrations — useful
for UI development, screenshots and CI without real hardware or accounts.

Nothing here talks to the network. Device names end in "(예시)" and every
device carries ``meta.demo = True`` so example data is never mistaken for real.
"""
from __future__ import annotations

import copy
import io
import os
import threading
import time
from typing import Any

from .. import capabilities as cap
from .. import vacuum_map
from ..models import Device
from .cloud_base import CloudAdapter

ENV = "HOMEHUB_FAKE_DEVICES"


def enabled_by_env() -> bool:
    return os.environ.get(ENV, "").strip().lower() in ("1", "true", "yes", "on")


C = cap.CapabilityInstance

# Sample map: 20 mm per pixel, image y grows downwards, map y grows upwards
# (like Roborock), so the app really has to use the transform.
MM_PER_PX = 20
MAP_X0, MAP_Y1 = 20000, 30000
IMG_W = IMG_H = 600
ROOMS = [  # id, name, x0, y0, x1, y1 (map mm), fill colour
    ("16", "거실", 20400, 22000, 26000, 29600, (120, 170, 230)),
    ("17", "주방", 26000, 25000, 31600, 29600, (240, 190, 110)),
    ("18", "침실", 26000, 18400, 31600, 25000, (160, 210, 150)),
    ("19", "욕실", 20400, 18400, 26000, 22000, (200, 160, 220)),
]
DOCK = {"x": 21200.0, "y": 28800.0}


def _to_px(x: float, y: float) -> tuple[float, float]:
    return (x - MAP_X0) / MM_PER_PX, (MAP_Y1 - y) / MM_PER_PX


def _calibration() -> list[dict[str, Any]]:
    pts = [(MAP_X0, MAP_Y1), (MAP_X0 + 10000, MAP_Y1), (MAP_X0, MAP_Y1 - 10000)]
    return [{"map": {"x": float(x), "y": float(y)},
             "image": dict(zip("xy", map(float, _to_px(x, y))))} for x, y in pts]


def render_map_png() -> bytes:
    from PIL import Image, ImageDraw  # Pillow comes with python-roborock's map parser

    img = Image.new("RGB", (IMG_W, IMG_H), (40, 44, 52))
    d = ImageDraw.Draw(img)
    for _id, _name, x0, y0, x1, y1, fill in ROOMS:
        u0, v1 = _to_px(x0, y0)
        u1, v0 = _to_px(x1, y1)
        d.rectangle([u0, v0, u1, v1], fill=fill, outline=(30, 30, 30), width=4)
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    return buf.getvalue()


def _sample_devices() -> list[Device]:
    tv = Device(
        id="demo:tv", name="거실 TV (예시)", adapter="demo", kind="tv", vendor="Example",
        reachable=True, controllable=True, meta={"demo": True, "room": "거실", "model": "Example TV"},
        capabilities={
            cap.POWER: C(cap.POWER, ["turnOn", "turnOff", "toggle"], {"switch": "on"}),
            cap.VOLUME: C(cap.VOLUME, ["setLevel", "volumeUp", "volumeDown", "mute", "unmute"],
                          {"level": 18, "muted": False}),
            cap.CHANNEL: C(cap.CHANNEL, ["channelUp", "channelDown", "setChannel"], {"channel": "11"}),
            cap.MEDIA_INPUT: C(cap.MEDIA_INPUT, ["select"],
                               {"sources": ["TV", "HDMI1", "HDMI2", "USB"], "selected": "TV"}),
            cap.MEDIA_PLAYBACK: C(cap.MEDIA_PLAYBACK, ["play", "pause", "stop", "next", "previous"],
                                  {"status": "playing"}),
            cap.LAUNCH_APP: C(cap.LAUNCH_APP, ["open"], {"apps": ["Netflix", "YouTube", "Browser"]}),
        })
    washer = Device(
        id="demo:washer", name="세탁기 (예시)", adapter="demo", kind="washer", vendor="Example",
        reachable=True, controllable=True, meta={"demo": True, "room": "다용도실"},
        capabilities={
            cap.WASHER: C(cap.WASHER, ["start", "pause", "stop"], {
                "machineState": "run", "jobState": "rinse", "remainingMinutes": 42,
                "completionTime": None, "remoteControlEnabled": False}),
        })
    fridge = Device(
        id="demo:fridge", name="냉장고 (예시)", adapter="demo", kind="refrigerator", vendor="Example",
        reachable=True, controllable=True, meta={"demo": True, "room": "주방"},
        capabilities={
            cap.REFRIGERATION: C(cap.REFRIGERATION, ["setFridgeSetpoint", "setFreezerSetpoint",
                                                     "setRapidCooling", "setRapidFreezing"], {
                "unit": "C", "fridgeTemperature": 3.4, "freezerTemperature": -18.6,
                "fridgeSetpoint": 3, "freezerSetpoint": -19, "doorOpen": False,
                "doors": {"fridge": False, "freezer": False},
                "rapidCooling": False, "rapidFreezing": True}),
        })
    rooms = [{"id": r[0], "name": r[1]} for r in ROOMS]
    vacuum = Device(
        id="demo:vacuum", name="로봇청소기 (예시)", adapter="demo", kind="vacuum", vendor="Example",
        reachable=True, controllable=True,
        meta={"demo": True, "room": "거실", "robot": {"x": 23500.0, "y": 26000.0, "angle": 90}},
        capabilities={
            cap.VACUUM: C(cap.VACUUM, ["start", "pause", "stop", "dock"], {
                "status": "docked", "battery": 87, "cleaningMode": None, "cleaningModes": [],
                "error": None, "dockError": None}),
            cap.ROOM_CLEANING: C(cap.ROOM_CLEANING, ["cleanRooms"], {"rooms": rooms, "maxRepeat": 3}),
            cap.ZONE_CLEANING: C(cap.ZONE_CLEANING, ["cleanZones"],
                                 {"maxZones": 5, "maxRepeat": 3, "coordinateSpace": "map"}),
            cap.GO_TO: C(cap.GO_TO, ["goTo"], {"coordinateSpace": "map"}),
            cap.FAN_SPEED: C(cap.FAN_SPEED, ["setLevel"],
                             {"level": "balanced", "levels": ["quiet", "balanced", "turbo", "max"]}),
            cap.MOPPING: C(cap.MOPPING, ["setWaterLevel", "setMopMode"], {
                "waterLevel": "medium", "waterLevels": ["off", "low", "medium", "high"],
                "mopMode": "standard", "mopModes": ["standard", "deep", "fast"]}),
            cap.CONSUMABLES: C(cap.CONSUMABLES, ["reset"], {"items": [
                {"id": "mainBrush", "name": "Main brush", "usedHours": 120.5, "remainingPercent": 60, "resettable": True},
                {"id": "sideBrush", "name": "Side brush", "usedHours": 150.0, "remainingPercent": 25, "resettable": True},
                {"id": "filter", "name": "Filter", "usedHours": 140.2, "remainingPercent": 7, "resettable": True},
                {"id": "sensors", "name": "Sensors", "usedHours": 12.0, "remainingPercent": 60, "resettable": True},
            ]}),
            cap.CLEANING_STATS: C(cap.CLEANING_STATS, [], {"areaM2": 42.5, "durationSeconds": 2710}),
            cap.VACUUM_MAP: C(cap.VACUUM_MAP, [], {"available": True}),
        })
    light = Device(
        id="demo:light", name="침실 조명 (예시)", adapter="demo", kind="light", vendor="Example",
        reachable=True, controllable=True, meta={"demo": True, "room": "침실"},
        capabilities={
            cap.POWER: C(cap.POWER, ["turnOn", "turnOff", "toggle"], {"switch": "off"}),
            cap.BRIGHTNESS: C(cap.BRIGHTNESS, ["setLevel"], {"level": 70}),
            cap.COLOR: C(cap.COLOR, ["setColor", "setColorTemperature"],
                         {"hue": 30, "saturation": 40, "kelvin": 3000}),
        })
    lock = Device(
        id="demo:lock", name="현관 도어락 (예시)", adapter="demo", kind="lock", vendor="Example",
        reachable=True, controllable=True, meta={"demo": True, "room": "현관"},
        capabilities={
            cap.LOCK: C(cap.LOCK, ["lock", "unlock"], {"locked": True}),
            cap.SENSOR: C(cap.SENSOR, [], {"readings": {"battery": 64}}),
        })
    stream = {"protocol": "demo", "rtspUrl": None, "profiles": [
        {"token": "main", "name": "Main", "width": 640, "height": 360, "codec": "MJPEG"}],
        "selectedProfile": "main", "snapshotAvailable": True, "mjpegAvailable": True, "audio": False}
    cam_living = Device(
        id="demo:cam-living", name="거실 카메라 (예시)", adapter="demo", kind="camera", vendor="Example",
        reachable=True, controllable=True,
        meta={"demo": True, "room": "거실", "scene": "living", "ptzPos": {"pan": 0.0, "tilt": 0.0}},
        capabilities={
            cap.VIDEO_STREAM: C(cap.VIDEO_STREAM, [], dict(stream)),
            cap.PTZ: C(cap.PTZ, ["move", "stop", "gotoPreset"], {
                "panTilt": True, "zoom": True,
                "presets": [{"token": "1", "name": "소파"}, {"token": "2", "name": "현관 쪽"}]}),
            # Home Summary camera line reads these (docs/home-summary.md, "Camera contract").
            cap.SENSOR: C(cap.SENSOR, [], {"readings": {"visitorCount": 0, "motion": 0}}),
        })
    cam_door = Device(
        id="demo:cam-door", name="현관 카메라 (예시)", adapter="demo", kind="camera", vendor="Example",
        reachable=True, controllable=True, meta={"demo": True, "room": "현관", "scene": "door"},
        capabilities={
            cap.VIDEO_STREAM: C(cap.VIDEO_STREAM, [], dict(stream)),
            cap.SENSOR: C(cap.SENSOR, [], {"readings": {"visitorCount": 2, "motion": 0}}),
        })
    return [tv, washer, fridge, vacuum, light, lock, cam_living, cam_door]


CAM_W, CAM_H = 640, 360
_PRESETS = {"1": (-0.5, 0.0), "2": (0.6, 0.1)}


def render_camera_jpeg(scene: str, pan: float = 0.0, tilt: float = 0.0, tick: int = 0) -> bytes:
    """Synthetic camera picture (a drawn room / doorway, NOT a real feed).
    ``pan``/``tilt`` in -1..1 slide the scene so PTZ visibly does something."""
    from PIL import Image, ImageDraw

    W, H = CAM_W * 2, CAM_H * 2                        # scene is larger than the viewport
    img = Image.new("RGB", (W, H), (58, 62, 70))
    d = ImageDraw.Draw(img)
    if scene == "door":
        d.rectangle([0, 0, W, H * 0.62], fill=(196, 190, 178))              # wall
        d.rectangle([W * 0.36, H * 0.12, W * 0.64, H * 0.66], fill=(112, 78, 52), outline=(60, 40, 26), width=8)
        d.ellipse([W * 0.59, H * 0.40, W * 0.61, H * 0.43], fill=(230, 200, 90))   # door handle
        d.rectangle([0, H * 0.66, W, H], fill=(120, 124, 130))               # floor
        d.rectangle([W * 0.10, H * 0.70, W * 0.28, H * 0.78], fill=(90, 60, 40))    # shoe rack
    else:
        d.rectangle([0, 0, W, H * 0.6], fill=(214, 206, 190))                # wall
        d.rectangle([0, H * 0.6, W, H], fill=(150, 112, 78))                 # wooden floor
        d.rectangle([W * 0.12, H * 0.42, W * 0.46, H * 0.72], fill=(88, 112, 150), outline=(50, 64, 90), width=6)  # sofa
        d.rectangle([W * 0.60, H * 0.10, W * 0.86, H * 0.42], fill=(150, 200, 235), outline=(255, 255, 255), width=10)  # window
        d.rectangle([W * 0.62, H * 0.50, W * 0.84, H * 0.58], fill=(40, 40, 44))                                   # TV stand
        d.ellipse([W * 0.50, H * 0.72, W * 0.58, H * 0.80], fill=(190, 80, 70))                                    # ball
    ox = int((W - CAM_W) / 2 + pan * (W - CAM_W) / 2)
    oy = int((H - CAM_H) / 2 - tilt * (H - CAM_H) / 2)
    view = img.crop((ox, oy, ox + CAM_W, oy + CAM_H))
    v = ImageDraw.Draw(view)
    v.rectangle([0, 0, CAM_W, 26], fill=(0, 0, 0))
    v.text((8, 6), f"EXAMPLE CAMERA (demo)   {scene}   t={tick}", fill=(255, 255, 255))
    buf = io.BytesIO()
    view.save(buf, format="JPEG", quality=80)
    return buf.getvalue()


def _home_devices() -> list[Device]:
    """Extra sample devices for the home summary + automation demos (lights, curtains). Kept apart from
    ``_sample_devices``. The demo cameras (``demo:cam-living`` / ``demo:cam-door``) carry the
    ``sensor`` readings the Home Summary camera line reads."""
    living_light = Device(
        id="demo:light-living", name="거실 조명 (예시)", adapter="demo", kind="light", vendor="Example",
        reachable=True, controllable=True, meta={"demo": True, "room": "거실"},
        capabilities={
            cap.POWER: C(cap.POWER, ["turnOn", "turnOff", "toggle"], {"switch": "on"}),
            cap.BRIGHTNESS: C(cap.BRIGHTNESS, ["setLevel"], {"level": 100}),
        })
    kitchen_light = Device(
        id="demo:light-kitchen", name="주방 조명 (예시)", adapter="demo", kind="light", vendor="Example",
        reachable=True, controllable=True, meta={"demo": True, "room": "주방"},
        capabilities={cap.POWER: C(cap.POWER, ["turnOn", "turnOff", "toggle"], {"switch": "off"})})
    bath_light = Device(
        id="demo:light-bath", name="욕실 조명 (예시)", adapter="demo", kind="light", vendor="Example",
        reachable=True, controllable=True, meta={"demo": True, "room": "욕실"},
        capabilities={cap.POWER: C(cap.POWER, ["turnOn", "turnOff", "toggle"], {"switch": "off"})})
    bed_curtain = Device(
        id="demo:curtain-bedroom", name="침실 커튼 (예시)", adapter="demo", kind="curtain", vendor="Example",
        reachable=True, controllable=True, meta={"demo": True, "room": "침실"},
        capabilities={
            cap.CURTAIN: C(cap.CURTAIN, ["open", "close", "stop", "setPosition"],
                           {"position": 100, "status": "open"}),
        })
    living_curtain = Device(
        id="demo:curtain-living", name="거실 커튼 (예시)", adapter="demo", kind="curtain", vendor="Example",
        reachable=True, controllable=True, meta={"demo": True, "room": "거실"},
        capabilities={
            cap.CURTAIN: C(cap.CURTAIN, ["open", "close", "stop", "setPosition"],
                           {"position": 60, "status": "partial"}),
        })
    return [living_light, kitchen_light, bath_light, bed_curtain, living_curtain]


class DemoAdapter(CloudAdapter):
    id = "demo"
    name = "Demo devices (example data)"

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._devices: dict[str, Device] = {d.id: d for d in [*_sample_devices(), *_home_devices()]}

    def enabled(self) -> bool:
        return enabled_by_env()

    def list_devices(self) -> list[Device]:
        with self._lock:
            return [copy.deepcopy(d) for d in self._devices.values()]

    def refresh_state(self, device: Device) -> None:
        with self._lock:
            src = self._devices.get(device.id)
            if src is not None:
                device.capabilities = copy.deepcopy(src.capabilities)

    # ------------------------------------------------------------------ control
    def execute(self, device: Device, capability: str, action: str, params: dict[str, Any]) -> dict[str, Any]:
        cap.validate_action(capability, action)
        inst = device.capabilities.get(capability)
        if inst is None or action not in inst.actions:
            raise ValueError(f"{device.name} does not support {capability}.{action}")
        with self._lock:
            self._apply(device, inst.state, capability, action, params or {})
            self._devices[device.id] = copy.deepcopy(device)
        return {"ok": True, "method": "demo", "capability": capability, "action": action}

    def _apply(self, dev: Device, st: dict[str, Any], capability: str, action: str, p: dict[str, Any]) -> None:
        if capability == cap.POWER:
            st["switch"] = {"turnOn": "on", "turnOff": "off"}.get(
                action, "off" if st.get("switch") == "on" else "on")
        elif capability == cap.VOLUME:
            if action == "setLevel":
                st["level"] = _clamp(_num(p, "level"), 0, 100)
            elif action in ("volumeUp", "volumeDown"):
                st["level"] = _clamp(st.get("level", 0) + (1 if action == "volumeUp" else -1), 0, 100)
            else:
                st["muted"] = action == "mute"
        elif capability == cap.CHANNEL:
            if action == "setChannel":
                st["channel"] = str(p.get("channel") or "")
            else:
                n = int(st.get("channel") or 0) + (1 if action == "channelUp" else -1)
                st["channel"] = str(max(1, n))
        elif capability == cap.MEDIA_INPUT:
            if p.get("source") not in st.get("sources", []):
                raise ValueError(f"unknown source {p.get('source')!r}")
            st["selected"] = p["source"]
        elif capability == cap.MEDIA_PLAYBACK:
            st["status"] = {"play": "playing", "pause": "paused", "stop": "stopped"}.get(action, st.get("status"))
        elif capability == cap.LAUNCH_APP:
            if p.get("app") not in st.get("apps", []):
                raise ValueError(f"unknown app {p.get('app')!r}")
        elif capability == cap.BRIGHTNESS:
            st["level"] = _clamp(_num(p, "level"), 0, 100)
        elif capability == cap.COLOR:
            if action == "setColor":
                st["hue"], st["saturation"] = _clamp(_num(p, "hue"), 0, 360), _clamp(_num(p, "saturation"), 0, 100)
            else:
                st["kelvin"] = _clamp(_num(p, "kelvin"), 1500, 9000)
        elif capability == cap.LOCK:
            st["locked"] = action == "lock"
        elif capability == cap.CURTAIN:
            if action == "setPosition":
                pos = int(_clamp(_num(p, "position"), 0, 100))
            elif action == "stop":
                pos = st.get("position")
            else:
                pos = 100 if action == "open" else 0
            st["position"] = pos
            st["status"] = "unknown" if pos is None else "closed" if pos <= 0 else "open" if pos >= 100 else "partial"
        elif capability in (cap.WASHER, cap.DRYER):
            if action == "start":
                self.require_remote_start(st.get("remoteControlEnabled"), dev)
            st["machineState"] = {"start": "run", "pause": "pause", "stop": "stop"}[action]
            if action == "stop":
                st["jobState"], st["remainingMinutes"] = "none", None
        elif capability == cap.REFRIGERATION:
            if action == "setFridgeSetpoint":
                st["fridgeSetpoint"] = _in_range(_num(p, "temperature"), 1, 7)
            elif action == "setFreezerSetpoint":
                st["freezerSetpoint"] = _in_range(_num(p, "temperature"), -23, -15)
            elif action == "setRapidCooling":
                st["rapidCooling"] = bool(p.get("enabled"))
            else:
                st["rapidFreezing"] = bool(p.get("enabled"))
        elif capability == cap.VACUUM:
            st["status"] = {"start": "cleaning", "pause": "paused", "stop": "idle", "dock": "returning"}.get(
                action, st.get("status"))
        elif capability == cap.ROOM_CLEANING:
            known = {r["id"] for r in st.get("rooms", [])}
            ids = [str(i) for i in (p.get("roomIds") or [])]
            if not ids or any(i not in known for i in ids):
                raise ValueError(f"roomIds must be a non-empty subset of {sorted(known)}")
            _repeat(p, st.get("maxRepeat", 3))
            self._vac_status(dev, "cleaning")
        elif capability == cap.ZONE_CLEANING:
            zones = p.get("zones")
            if not isinstance(zones, list) or not zones or len(zones) > st.get("maxZones", 5):
                raise ValueError(f"zones must be a list of 1..{st.get('maxZones', 5)} [x1,y1,x2,y2]")
            for z in zones:
                if not isinstance(z, list) or len(z) != 4:
                    raise ValueError("each zone must be [x1, y1, x2, y2]")
            _repeat(p, st.get("maxRepeat", 3))
            self._vac_status(dev, "cleaning")
        elif capability == cap.GO_TO:
            x, y = _num(p, "x"), _num(p, "y")
            dev.meta["robot"] = {"x": float(x), "y": float(y), "angle": 0}
            self._vac_status(dev, "moving")
        elif capability == cap.FAN_SPEED:
            if p.get("level") not in st.get("levels", []):
                raise ValueError(f"level must be one of {st.get('levels')}")
            st["level"] = p["level"]
        elif capability == cap.MOPPING:
            key, opts, arg = (("waterLevel", "waterLevels", "level") if action == "setWaterLevel"
                              else ("mopMode", "mopModes", "mode"))
            if p.get(arg) not in st.get(opts, []):
                raise ValueError(f"{arg} must be one of {st.get(opts)}")
            st[key] = p[arg]
        elif capability == cap.PTZ:
            pos = dev.meta.setdefault("ptzPos", {"pan": 0.0, "tilt": 0.0})
            if action == "move":
                for k, key in (("pan", "pan"), ("tilt", "tilt")):
                    v = p.get(key, 0)
                    if isinstance(v, bool) or not isinstance(v, (int, float)) or not -1 <= v <= 1:
                        raise ValueError(f"'{key}' must be a number -1..1")
                    pos[k] = _clamp(pos[k] + 0.25 * v, -1, 1)
            elif action == "gotoPreset":
                if p.get("preset") not in _PRESETS:
                    raise ValueError("unknown preset")
                pos["pan"], pos["tilt"] = _PRESETS[p["preset"]]
        elif capability == cap.CONSUMABLES:
            item = next((i for i in st.get("items", []) if i["id"] == p.get("id")), None)
            if item is None or not item.get("resettable"):
                raise ValueError(f"unknown or non-resettable consumable {p.get('id')!r}")
            item["usedHours"], item["remainingPercent"] = 0.0, 100

    @staticmethod
    def _vac_status(dev: Device, status: str) -> None:
        if cap.VACUUM in dev.capabilities:
            dev.capabilities[cap.VACUUM].state["status"] = status

    # ------------------------------------------------------------------ camera
    def snapshot(self, device: Device) -> bytes:
        if cap.VIDEO_STREAM not in device.capabilities:
            raise ValueError(f"{device.name} is not a camera")
        with self._lock:
            src = self._devices.get(device.id) or device
            pos = dict(src.meta.get("ptzPos") or {})
            scene = src.meta.get("scene", "living")
        return render_camera_jpeg(scene, pos.get("pan", 0.0), pos.get("tilt", 0.0), int(time.time()) % 100000)

    def mjpeg_frames(self, device: Device, fps: int = 5):
        while True:
            yield self.snapshot(device)
            time.sleep(1.0 / max(1, fps))

    def stream_info(self, device: Device) -> dict[str, Any]:
        return {"rtspUrl": None, "requiresCredentials": False,
                "snapshotUrl": f"/devices/{device.id}/snapshot.jpg",
                "mjpegUrl": f"/devices/{device.id}/stream.mjpeg", "hlsUrl": None, "ffmpeg": False}

    # --------------------------------------------------------------------- map
    def get_map(self, device: Device) -> tuple[bytes | None, dict[str, Any]]:
        if cap.VACUUM_MAP not in device.capabilities:
            raise ValueError(f"{device.name} does not provide a map")
        with self._lock:
            robot = dict((self._devices.get(device.id) or device).meta.get("robot") or {})
        png = render_map_png()
        rooms = [{"id": r[0], "name": r[1], "x0": r[2], "y0": r[3], "x1": r[4], "y1": r[5]} for r in ROOMS]
        meta = vacuum_map.build_metadata(_calibration(), rooms, robot or None, dict(DOCK), png,
                                         map_name="예시 지도 (example)")
        meta["demo"] = True
        return png, meta


def _num(p: dict[str, Any], key: str) -> float:
    v = p.get(key)
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        raise ValueError(f"'{key}' must be a number")
    return v


def _clamp(v: float, lo: float, hi: float) -> float:
    return max(lo, min(hi, v))


def _in_range(v: float, lo: float, hi: float) -> float:
    if not lo <= v <= hi:
        raise ValueError(f"temperature must be between {lo} and {hi}")
    return v


def _repeat(p: dict[str, Any], max_repeat: int) -> int:
    r = p.get("repeat", 1)
    if isinstance(r, bool) or not isinstance(r, int) or not 1 <= r <= max_repeat:
        raise ValueError(f"'repeat' must be an integer 1..{max_repeat}")
    return r
