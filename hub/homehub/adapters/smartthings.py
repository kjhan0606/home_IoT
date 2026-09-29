"""Samsung SmartThings cloud adapter (official REST API).

API: https://api.smartthings.com/v1
  GET  /devices                    (paginated via _links.next.href)
  GET  /devices/{id}/status        {"components": {comp: {cap: {attr: {"value", "unit"}}}}}
  POST /devices/{id}/commands      {"commands": [{component, capability, command, arguments}]}

Auth: ``Authorization: Bearer <token>`` from a ``TokenProvider``. Default is a
Personal Access Token in ``SMARTTHINGS_TOKEN`` (scopes r:devices:* x:devices:*).
NOTE: PATs created after 2024-12-30 are valid for 24 h only; long-running use
needs the OAuth2 provider (cloud/auth.py, docs/cloud-integrations.md).

SmartThings -> canonical translation (per component):
  switch | light                           -> power   (light on/off; kind "light" by category)
  windowShade (+ windowShadeLevel)         -> curtain  (open/close/pause/setShadeLevel)
  audioVolume + audioMute                  -> volume
  tvChannel                                -> channel
  mediaInputSource | samsungvd.mediaInputSource -> mediaInput
  mediaPlayback (+ mediaTrackControl)      -> mediaPlayback
  switchLevel -> brightness,  lock -> lock
  washerOperatingState (+ remoteControlStatus, samsungce.washerOperatingState) -> washer
  dryerOperatingState  (+ remoteControlStatus, samsungce.dryerOperatingState)  -> dryer
  refrigeration, temperatureMeasurement, thermostatCoolingSetpoint,
  contactSensor, samsungce.powerCool/powerFreeze (per cooler/freezer comp) -> refrigeration
  robotCleanerMovement + robotCleanerCleaningMode + battery -> vacuum
"""
from __future__ import annotations

import math
import os
from datetime import datetime, timezone
from typing import Any

from .. import capabilities as cap
from ..cloud.auth import EnvTokenProvider, TokenProvider
from ..cloud.errors import CloudAPIError, CloudAuthError
from ..models import Device
from .cloud_base import CloudAdapter

DEFAULT_BASE = "https://api.smartthings.com/v1"

_CATEGORY_KIND = {
    "television": "tv",
    "washer": "washer",
    "dryer": "dryer",
    "refrigerator": "refrigerator",
    "kimchirefrigerator": "refrigerator",
    "robotcleaner": "vacuum",
    "light": "light",
    "curtain": "curtain",
    "blind": "curtain",
    "switch": "switch",
    "smartplug": "switch",
    "smartlock": "lock",
    "speaker": "speaker",
    "networkaudio": "speaker",
    "airconditioner": "air-conditioner",
    "dishwasher": "dishwasher",
    "mobile": "phone",
    "smartphone": "phone",
}

# robotCleanerMovement value -> canonical vacuum.status
_VACUUM_STATUS = {
    "cleaning": "cleaning",
    "point": "cleaning",
    "pause": "paused",
    "homing": "returning",
    "charging": "charging",
    "alarm": "error",
    "idle": "idle",
    "after": "idle",
    "reserve": "idle",
    "powerOff": "idle",
}
# windowShade attribute value -> canonical curtain.status
_SHADE_STATUS = {
    "open": "open",
    "closed": "closed",
    "opening": "opening",
    "closing": "closing",
    "partially open": "partial",
    "unknown": "unknown",
}


def _shade_status_from_level(level: Any) -> str:
    if isinstance(level, bool) or not isinstance(level, (int, float)):
        return "unknown"
    return "closed" if level <= 0 else "open" if level >= 100 else "partial"


# Enum from the robotCleanerCleaningMode capability definition.
_ST_CLEANING_MODES = ["auto", "part", "repeat", "manual", "stop", "map"]

# Samsung refrigerator component ids per compartment.
_FRIDGE_COMPS = ("cooler", "fridge", "onedoor")
_FREEZER_COMPS = ("freezer",)


def _bool_str(v: Any) -> bool | None:
    if v is None:
        return None
    if isinstance(v, bool):
        return v
    s = str(v).strip().lower()
    if s in ("true", "on", "open", "enabled", "1", "muted"):
        return True
    if s in ("false", "off", "closed", "disabled", "0", "unmuted"):
        return False
    return None


class SmartThingsAdapter(CloudAdapter):
    id = "smartthings"
    name = "Samsung SmartThings (cloud)"

    def __init__(
        self,
        tokens: TokenProvider | None = None,
        base_url: str | None = None,
        session: Any = None,
        timeout: float = 15,
    ) -> None:
        self.tokens = tokens or EnvTokenProvider(
            "SMARTTHINGS_TOKEN",
            hint="Create a Personal Access Token at https://account.smartthings.com/tokens "
            "(scopes: Devices read/execute).",
        )
        self.base_url = (base_url or os.environ.get("SMARTTHINGS_API_BASE") or DEFAULT_BASE).rstrip("/")
        self._session = session
        self.timeout = timeout

    # ---------------------------------------------------------------- HTTP --
    @property
    def session(self):
        if self._session is None:
            import requests

            self._session = requests.Session()
        return self._session

    def _request(self, method: str, path_or_url: str, json: Any = None) -> Any:
        url = path_or_url if path_or_url.startswith("http") else f"{self.base_url}{path_or_url}"
        headers = {
            "Authorization": f"Bearer {self.tokens.get_token()}",
            "Accept": "application/json",
        }
        try:
            r = self.session.request(method, url, headers=headers, json=json, timeout=self.timeout)
        except Exception as e:  # noqa: BLE001
            raise self._transport_error("SmartThings", method, url, e) from e
        if r.status_code in (401, 403):
            self.tokens.invalidate()
            raise CloudAuthError(
                f"SmartThings rejected the token ({r.status_code}). PATs issued after "
                "2024-12-30 expire after 24 h — create a new one or use OAuth. "
                f"Detail: {self._json_or_text(r)}"
            )
        if not (200 <= r.status_code < 300):
            raise CloudAPIError(
                f"SmartThings {method} {url} -> {r.status_code}: {self._json_or_text(r)}",
                status=r.status_code,
            )
        return r.json() if r.content else {}

    def _get_status(self, device_id: str) -> dict[str, Any]:
        return self._request("GET", f"/devices/{device_id}/status").get("components", {}) or {}

    def _send(self, device: Device, component: str, capability: str, command: str,
              arguments: list[Any] | None = None) -> dict[str, Any]:
        body = {
            "commands": [
                {
                    "component": component,
                    "capability": capability,
                    "command": command,
                    "arguments": arguments or [],
                }
            ]
        }
        resp = self._request("POST", f"/devices/{device.meta['cloudId']}/commands", json=body)
        return {
            "ok": True,
            "method": "smartthings",
            "command": f"{component}/{capability}.{command}",
            "arguments": arguments or [],
            "response": resp.get("results", resp) if isinstance(resp, dict) else resp,
        }

    # ------------------------------------------------------------ discovery --
    def list_devices(self) -> list[Device]:
        items: list[dict[str, Any]] = []
        url: str | None = "/devices"
        while url:
            page = self._request("GET", url)
            items.extend(page.get("items", []))
            url = ((page.get("_links") or {}).get("next") or {}).get("href")
        devices = []
        for item in items:
            try:
                status = self._get_status(item["deviceId"])
            except CloudAuthError:
                raise
            except Exception:  # noqa: BLE001 - offline device: list it anyway
                status = {}
            devices.append(self.device_from_item(item, status))
        return devices

    # ---------------------------------------------------------- translation --
    def device_from_item(self, item: dict[str, Any], status: dict[str, Any]) -> Device:
        comp_caps: dict[str, set[str]] = {}
        categories: list[str] = []
        for comp in item.get("components", []) or []:
            comp_caps[comp.get("id", "main")] = {c.get("id") for c in comp.get("capabilities", [])}
            if comp.get("id") == "main":
                categories = [c.get("name", "") for c in comp.get("categories", [])]
        # If the listing lacked components, infer from status.
        if not comp_caps:
            comp_caps = {k: set(v.keys()) for k, v in status.items()}

        kind = self._kind(categories, comp_caps)
        caps, components = self._translate(comp_caps, status, kind)
        ocf = item.get("ocf") or {}
        brand = item.get("manufacturerName") or ocf.get("manufacturerName") or ""
        model = ocf.get("modelNumber") or item.get("deviceTypeName")
        name = item.get("label") or item.get("name") or item["deviceId"]
        health = (item.get("healthState") or {}).get("state")
        return Device(
            id=f"{self.id}:{item['deviceId']}",
            name=name,
            adapter=self.id,
            kind=kind,
            vendor=brand or None,
            reachable=health != "OFFLINE",
            controllable=bool(caps),
            capabilities=caps,
            meta={
                "cloudId": item["deviceId"],
                "source": "cloud",
                "model": model,
                "components": components,       # canonical cap(.part) -> ST component
                "stCapabilities": {k: sorted(v) for k, v in comp_caps.items()},
                "categories": categories,
                "match": {"brand": brand, "model": model, "name": name, "mac": None},
            },
        )

    @staticmethod
    def _kind(categories: list[str], comp_caps: dict[str, set[str]]) -> str:
        for c in categories:
            k = _CATEGORY_KIND.get(c.replace(" ", "").lower())
            if k:
                return k
        allcaps = set().union(*comp_caps.values()) if comp_caps else set()
        if "washerOperatingState" in allcaps:
            return "washer"
        if "dryerOperatingState" in allcaps:
            return "dryer"
        if "refrigeration" in allcaps or {"cooler", "freezer"} & set(comp_caps):
            return "refrigerator"
        if "robotCleanerMovement" in allcaps:
            return "vacuum"
        if "tvChannel" in allcaps:
            return "tv"
        if "windowShade" in allcaps or "windowShadeLevel" in allcaps:
            return "curtain"
        if "switch" in allcaps or "light" in allcaps:
            return "switch"
        return "unknown"

    def _translate(self, comp_caps: dict[str, set[str]], st: dict[str, Any], kind: str):
        def val(comp: str, capability: str, attr: str, default: Any = None) -> Any:
            v = ((st.get(comp) or {}).get(capability) or {}).get(attr) or {}
            return v.get("value", default) if isinstance(v, dict) else default

        def unit(comp: str, capability: str, attr: str) -> str | None:
            v = ((st.get(comp) or {}).get(capability) or {}).get(attr) or {}
            return v.get("unit") if isinstance(v, dict) else None

        main = comp_caps.get("main", set())
        caps: dict[str, cap.CapabilityInstance] = {}
        comps: dict[str, str] = {}

        def add(key: str, actions: list[str], state: dict[str, Any], comp: str = "main") -> None:
            caps[key] = cap.CapabilityInstance(key=key, actions=actions, state=state)
            comps[key] = comp

        if "switch" in main:
            add(cap.POWER, ["turnOn", "turnOff", "toggle"], {"switch": val("main", "switch", "switch", "unknown")})
        elif "light" in main:
            # Legacy ST "light" capability: same on/off commands and `switch` attribute.
            add(cap.POWER, ["turnOn", "turnOff", "toggle"], {"switch": val("main", "light", "switch", "unknown")})
            comps[cap.POWER + ".st"] = "light"

        # ---- curtain / blind ---------------------------------------------
        if "windowShade" in main or "windowShadeLevel" in main:
            acts = []
            if "windowShade" in main:
                supported = val("main", "windowShade", "supportedWindowShadeCommands") or ["open", "close", "pause"]
                acts += [a for a, c in (("open", "open"), ("close", "close"), ("stop", "pause")) if c in supported]
            if "windowShadeLevel" in main:
                acts.append("setPosition")
                if not {"open", "close"} & set(acts):
                    acts += ["open", "close"]      # emulate with 100 / 0
            level = val("main", "windowShadeLevel", "shadeLevel") if "windowShadeLevel" in main else None
            state_str = val("main", "windowShade", "windowShade") if "windowShade" in main else None
            add(cap.CURTAIN, acts, {
                "position": int(level) if isinstance(level, (int, float)) and not isinstance(level, bool) else None,
                "status": _SHADE_STATUS.get(state_str, _shade_status_from_level(level)),
            })

        if "audioVolume" in main or "audioMute" in main:
            acts: list[str] = []
            if "audioVolume" in main:
                acts += ["setLevel", "volumeUp", "volumeDown"]
            if "audioMute" in main:
                acts += ["mute", "unmute"]
            add(cap.VOLUME, acts, {
                "level": val("main", "audioVolume", "volume"),
                "muted": _bool_str(val("main", "audioMute", "mute")),
            })

        if "tvChannel" in main:
            add(cap.CHANNEL, ["channelUp", "channelDown", "setChannel"],
                {"channel": val("main", "tvChannel", "tvChannel")})

        if "samsungvd.mediaInputSource" in main:
            smap = val("main", "samsungvd.mediaInputSource", "supportedInputSourcesMap") or []
            sources = [s.get("id") for s in smap if isinstance(s, dict) and s.get("id")]
            add(cap.MEDIA_INPUT, ["select"], {
                "sources": sources,
                "selected": val("main", "samsungvd.mediaInputSource", "inputSource"),
            })
            comps[cap.MEDIA_INPUT + ".st"] = "samsungvd.mediaInputSource"
        elif "mediaInputSource" in main:
            add(cap.MEDIA_INPUT, ["select"], {
                "sources": list(val("main", "mediaInputSource", "supportedInputSources") or []),
                "selected": val("main", "mediaInputSource", "inputSource"),
            })
            comps[cap.MEDIA_INPUT + ".st"] = "mediaInputSource"

        if "mediaPlayback" in main:
            acts = ["play", "pause", "stop"]
            if "mediaTrackControl" in main:
                acts += ["next", "previous"]
            add(cap.MEDIA_PLAYBACK, acts, {"status": val("main", "mediaPlayback", "playbackStatus")})

        if "switchLevel" in main:
            add(cap.BRIGHTNESS, ["setLevel"], {"level": val("main", "switchLevel", "level")})
        if "lock" in main:
            add(cap.LOCK, ["lock", "unlock"], {"locked": val("main", "lock", "lock") == "locked"})

        # ---- laundry -----------------------------------------------------
        for key, st_cap, job_attr in (
            (cap.WASHER, "washerOperatingState", "washerJobState"),
            (cap.DRYER, "dryerOperatingState", "dryerJobState"),
        ):
            if st_cap not in main:
                continue
            machine = val("main", st_cap, "machineState")
            supported = val("main", st_cap, "supportedMachineStates") or ["run", "pause", "stop"]
            acts = [a for a, s in (("start", "run"), ("pause", "pause"), ("stop", "stop")) if s in supported]
            completion = val("main", st_cap, "completionTime")
            remaining = None
            sce = "samsungce." + st_cap
            if sce in main and val("main", sce, "remainingTime") is not None:
                remaining = int(val("main", sce, "remainingTime"))
            elif machine == "run" and completion:
                remaining = _minutes_until(completion)
            elif machine == "stop":
                remaining = 0
            add(key, acts, {
                "machineState": machine,
                "jobState": val("main", st_cap, job_attr),
                "remainingMinutes": remaining,
                "completionTime": completion,
                "remoteControlEnabled": _bool_str(val("main", "remoteControlStatus", "remoteControlEnabled"))
                if "remoteControlStatus" in main else None,
            })

        # ---- refrigerator ------------------------------------------------
        fridge_c = next((c for c in _FRIDGE_COMPS if c in comp_caps), None)
        freezer_c = next((c for c in _FREEZER_COMPS if c in comp_caps), None)
        if fridge_c is None and kind == "refrigerator" and "thermostatCoolingSetpoint" in main:
            fridge_c = "main"
        if "refrigeration" in main or fridge_c or freezer_c:
            acts = []
            state: dict[str, Any] = {"unit": None, "doors": {}}
            for part, comp in (("fridge", fridge_c), ("freezer", freezer_c)):
                cc = comp_caps.get(comp, set()) if comp else set()
                state[f"{part}Temperature"] = val(comp, "temperatureMeasurement", "temperature") if comp else None
                state[f"{part}Setpoint"] = val(comp, "thermostatCoolingSetpoint", "coolingSetpoint") if comp else None
                if comp and "thermostatCoolingSetpoint" in cc:
                    acts.append("setFridgeSetpoint" if part == "fridge" else "setFreezerSetpoint")
                    comps[f"{cap.REFRIGERATION}.{part}"] = comp
                    state["unit"] = state["unit"] or unit(comp, "thermostatCoolingSetpoint", "coolingSetpoint")
                if comp:
                    state["unit"] = state["unit"] or unit(comp, "temperatureMeasurement", "temperature")
            for comp, cc in comp_caps.items():
                if "contactSensor" in cc and (comp in ("main", fridge_c, freezer_c)):
                    state["doors"][comp] = val(comp, "contactSensor", "contact") == "open"
            state["doorOpen"] = any(state["doors"].values()) if state["doors"] else None
            if "refrigeration" in main:
                acts += ["setRapidCooling", "setRapidFreezing"]
                state["rapidCooling"] = _bool_str(val("main", "refrigeration", "rapidCooling"))
                state["rapidFreezing"] = _bool_str(val("main", "refrigeration", "rapidFreezing"))
            else:
                # ASSUMPTION: samsungce.powerCool/powerFreeze expose an
                # "activated" attribute + activate/deactivate commands (from the
                # public capability presentation; not verified on hardware).
                state["rapidCooling"] = _bool_str(val("main", "samsungce.powerCool", "activated"))
                state["rapidFreezing"] = _bool_str(val("main", "samsungce.powerFreeze", "activated"))
                if "samsungce.powerCool" in main:
                    acts.append("setRapidCooling")
                if "samsungce.powerFreeze" in main:
                    acts.append("setRapidFreezing")
            state["unit"] = state["unit"] or "C"
            add(cap.REFRIGERATION, acts, state)

        # ---- robot vacuum ------------------------------------------------
        if "robotCleanerMovement" in main or "robotCleanerCleaningMode" in main:
            movement = val("main", "robotCleanerMovement", "robotCleanerMovement")
            acts = []
            if "robotCleanerMovement" in main:
                acts += ["start", "pause", "dock"]
            if "robotCleanerCleaningMode" in main:
                acts += ["stop", "setCleaningMode"]
                if "start" not in acts:
                    acts.insert(0, "start")
            batt = val("main", "battery", "battery") if "battery" in main else None
            status = _VACUUM_STATUS.get(movement or "", "idle")
            add(cap.VACUUM, acts, {
                "status": status,
                "battery": batt,
                "cleaningMode": val("main", "robotCleanerCleaningMode", "robotCleanerCleaningMode"),
                "cleaningModes": list(_ST_CLEANING_MODES) if "robotCleanerCleaningMode" in main else [],
            })

        return caps, comps

    # ------------------------------------------------------------- control --
    def execute(self, device: Device, capability: str, action: str, params: dict[str, Any]) -> dict[str, Any]:
        cap.validate_action(capability, action)
        comp = (device.meta.get("components") or {}).get(capability, "main")
        st_caps = set((device.meta.get("stCapabilities") or {}).get("main", []))

        if capability == cap.POWER:
            if action == "toggle":
                cur = (device.capabilities.get(cap.POWER) or cap.CapabilityInstance(cap.POWER)).state.get("switch")
                action = "turnOff" if cur == "on" else "turnOn"
            st_cap = (device.meta.get("components") or {}).get(cap.POWER + ".st", "switch")
            return self._send(device, comp, st_cap, "on" if action == "turnOn" else "off")

        if capability == cap.CURTAIN:
            has_shade = "windowShade" in st_caps
            has_level = "windowShadeLevel" in st_caps
            if action == "setPosition":
                pos = _int_param(params, "position", 0, 100)
                return self._send(device, comp, "windowShadeLevel", "setShadeLevel", [pos])
            if action in ("open", "close") and not has_shade and has_level:
                return self._send(device, comp, "windowShadeLevel", "setShadeLevel",
                                  [100 if action == "open" else 0])
            st_cmd = {"open": "open", "close": "close", "stop": "pause"}[action]
            return self._send(device, comp, "windowShade", st_cmd)

        if capability == cap.VOLUME:
            if action == "setLevel":
                level = _int_param(params, "level", 0, 100)
                return self._send(device, comp, "audioVolume", "setVolume", [level])
            if action in ("volumeUp", "volumeDown"):
                return self._send(device, comp, "audioVolume", action)
            return self._send(device, comp, "audioMute", action)   # mute / unmute

        if capability == cap.CHANNEL:
            if action == "setChannel":
                ch = str(params.get("channel", "")).strip()
                if not ch:
                    raise ValueError("setChannel requires 'channel'")
                return self._send(device, comp, "tvChannel", "setTvChannel", [ch])
            return self._send(device, comp, "tvChannel", action)

        if capability == cap.MEDIA_INPUT:
            src = str(params.get("source", "")).strip()
            if not src:
                raise ValueError("select requires 'source'")
            st_cap = (device.meta.get("components") or {}).get(cap.MEDIA_INPUT + ".st", "mediaInputSource")
            return self._send(device, comp, st_cap, "setInputSource", [src])

        if capability == cap.MEDIA_PLAYBACK:
            if action in ("next", "previous"):
                return self._send(device, comp, "mediaTrackControl", action + "Track")
            return self._send(device, comp, "mediaPlayback", action)

        if capability == cap.BRIGHTNESS:
            return self._send(device, comp, "switchLevel", "setLevel", [_int_param(params, "level", 0, 100)])

        if capability == cap.LOCK:
            return self._send(device, comp, "lock", action)

        if capability in (cap.WASHER, cap.DRYER):
            st_cap = "washerOperatingState" if capability == cap.WASHER else "dryerOperatingState"
            if action == "start":
                # Re-read the live flag: the user may have toggled it since the last scan.
                live = self._get_status(device.meta["cloudId"])
                flag = None
                if "remoteControlStatus" in st_caps:
                    v = (((live.get("main") or {}).get("remoteControlStatus") or {})
                         .get("remoteControlEnabled") or {}).get("value")
                    flag = _bool_str(v)
                self.require_remote_start(flag, device)
            state = {"start": "run", "pause": "pause", "stop": "stop"}[action]
            return self._send(device, comp, st_cap, "setMachineState", [state])

        if capability == cap.REFRIGERATION:
            comps = device.meta.get("components") or {}
            if action in ("setFridgeSetpoint", "setFreezerSetpoint"):
                part = "fridge" if action == "setFridgeSetpoint" else "freezer"
                target = comps.get(f"{cap.REFRIGERATION}.{part}")
                if not target:
                    raise ValueError(f"device has no controllable {part} compartment")
                t = _num_param(params, "temperature")
                return self._send(device, target, "thermostatCoolingSetpoint", "setCoolingSetpoint", [t])
            enabled = _bool_param(params, "enabled")
            if "refrigeration" in st_caps:
                cmd = "setRapidCooling" if action == "setRapidCooling" else "setRapidFreezing"
                return self._send(device, "main", "refrigeration", cmd, ["on" if enabled else "off"])
            sce = "samsungce.powerCool" if action == "setRapidCooling" else "samsungce.powerFreeze"
            return self._send(device, "main", sce, "activate" if enabled else "deactivate")

        if capability == cap.VACUUM:
            # ASSUMPTION: standard robotCleaner* capabilities accept these enum
            # values as commands (per the capability definitions). Newer Samsung
            # Jet Bots use samsungce.robotCleanerOperatingState, not handled yet.
            if action == "setCleaningMode":
                mode = str(params.get("mode", "")).strip()
                if mode not in _ST_CLEANING_MODES:
                    raise ValueError(f"mode must be one of {_ST_CLEANING_MODES}")
                return self._send(device, comp, "robotCleanerCleaningMode", "setRobotCleanerCleaningMode", [mode])
            if action == "stop":
                return self._send(device, comp, "robotCleanerCleaningMode", "setRobotCleanerCleaningMode", ["stop"])
            if action == "start" and "robotCleanerMovement" not in st_caps:
                return self._send(device, comp, "robotCleanerCleaningMode", "setRobotCleanerCleaningMode", ["auto"])
            movement = {"start": "cleaning", "pause": "pause", "dock": "homing"}[action]
            return self._send(device, comp, "robotCleanerMovement", "setRobotCleanerMovement", [movement])

        raise ValueError(f"unsupported: {capability}.{action}")

    # ------------------------------------------------------------- refresh --
    def refresh_state(self, device: Device) -> None:
        status = self._get_status(device.meta["cloudId"])
        comp_caps = {k: set(v) for k, v in (device.meta.get("stCapabilities") or {}).items()}
        caps, comps = self._translate(comp_caps, status, device.kind)
        for key, inst in caps.items():
            if key in device.capabilities:
                device.capabilities[key].state = inst.state
        device.reachable = True


# ------------------------------------------------------------------ helpers --
def _minutes_until(iso: str) -> int | None:
    try:
        t = datetime.fromisoformat(iso.replace("Z", "+00:00"))
    except ValueError:
        return None
    if t.tzinfo is None:
        t = t.replace(tzinfo=timezone.utc)
    secs = (t - datetime.now(timezone.utc)).total_seconds()
    return max(0, math.ceil(secs / 60))


def _int_param(params: dict[str, Any], key: str, lo: int, hi: int) -> int:
    try:
        v = int(params[key])
    except (KeyError, TypeError, ValueError):
        raise ValueError(f"'{key}' must be an integer {lo}..{hi}") from None
    if not lo <= v <= hi:
        raise ValueError(f"'{key}' must be within {lo}..{hi}")
    return v


def _num_param(params: dict[str, Any], key: str) -> float | int:
    try:
        v = float(params[key])
    except (KeyError, TypeError, ValueError):
        raise ValueError(f"'{key}' must be a number") from None
    return int(v) if v.is_integer() else v


def _bool_param(params: dict[str, Any], key: str) -> bool:
    v = params.get(key)
    if isinstance(v, bool):
        return v
    b = _bool_str(v)
    if b is None:
        raise ValueError(f"'{key}' must be true or false")
    return b
