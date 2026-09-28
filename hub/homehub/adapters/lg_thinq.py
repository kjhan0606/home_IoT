"""LG ThinQ Connect cloud adapter (official LG "ThinQ API" for individuals).

Sources (verified 2026-09): LG Smart Solution API developer site
(https://smartsolution.developer.lge.com — ThinQ Connect / PAT docs) and LG's
official Apache-2.0 Python SDK ``thinq-connect/pythinqconnect`` (thinq_api.py,
country.py, devices/*.py), which is what we mirror here.

  Base URL : https://api-{region}.lgthinq.com   region: kic (KR & Asia-Pacific),
             aic (Americas), eic (Europe/Middle-East/Africa) — derived from
             x-country exactly like the SDK's country table.
  Headers  : Authorization: Bearer <PAT>, x-country, x-message-id (fresh
             22-char base64url of a UUID per request), x-client-id (stable per
             client), x-api-key (public key published in the SDK), x-service-phase: OP;
             control calls add x-conditional-control: true.
  GET  /devices                  -> response: [{deviceId, deviceInfo:{deviceType, modelName, alias, reportable}}]
  GET  /devices/{id}/profile     -> response: {property: ...}  (r/w modes + allowed values)
  GET  /devices/{id}/state       -> response: current state (same resource layout)
  POST /devices/{id}/control     -> body: {resource: {property: value}} (+ location)
  Envelope: {"messageId", "timestamp", "response": ...} / {"error": {"code", "message"}}

ThinQ Connect does NOT cover LG TVs (no DEVICE_TV type exists in the API);
webOS TVs need a separate local adapter (SSAP) — out of scope here.

Assumptions (marked ASSUMPTION below) cover enum *values* that the public docs
only publish per device profile at runtime; we therefore read the device's
/profile and only expose actions whose values are writable.
"""
from __future__ import annotations

import base64
import os
import uuid
from typing import Any

from .. import capabilities as cap
from .. import config
from ..cloud.auth import EnvTokenProvider, TokenProvider
from ..cloud.errors import CloudAPIError, CloudAuthError, RemoteControlDisabledError
from ..models import Device
from .cloud_base import CloudAdapter

# Public client key shipped in LG's official SDK (thinqconnect/const.py API_KEY).
DEFAULT_API_KEY = "v6GFvkweNo7DK7yD3ylIZ9w52aKBU0eJ7wLXkSR3"

_KIC = set("AU BD CN HK ID IN JP KH KR LA LK MM MY NP NZ PH SG TH TW VN".split())
_AIC = set(
    "AG AR AW BB BO BR BS BZ CA CL CO CR CU DM DO EC GD GT GY HN HT JM KN LC MX "
    "NI PA PE PR PY SR SV TT US UY VC VE".split()
)

_TYPE_KIND = {
    "DEVICE_WASHER": "washer",
    "DEVICE_WASHTOWER_WASHER": "washer",
    "DEVICE_WASHCOMBO_MAIN": "washer",
    "DEVICE_WASHCOMBO_MINI": "washer",
    "DEVICE_DRYER": "dryer",
    "DEVICE_WASHTOWER_DRYER": "dryer",
    "DEVICE_REFRIGERATOR": "refrigerator",
    "DEVICE_ROBOT_CLEANER": "vacuum",
}
# Known but not (yet) mapped to canonical capabilities -> listed as passive.
_TYPE_KIND_PASSIVE = {
    "DEVICE_WASHTOWER": "washer-dryer",
    "DEVICE_KIMCHI_REFRIGERATOR": "refrigerator",
    "DEVICE_STYLER": "styler",
    "DEVICE_DISH_WASHER": "dishwasher",
    "DEVICE_AIR_CONDITIONER": "air-conditioner",
    "DEVICE_AIR_PURIFIER": "air-purifier",
    "DEVICE_OVEN": "oven",
}

# ASSUMPTION: laundry operation-mode values. The SDK/HA integration expose
# START / STOP / POWER_OFF / WAKE_UP for washerOperationMode/dryerOperationMode;
# LG uses "STOP" for pausing a running course, and a course can only be ended
# remotely by powering the machine off.
_LAUNDRY_ACTION_VALUE = {"start": "START", "pause": "STOP", "stop": "POWER_OFF"}
# runState.currentState -> canonical machineState (everything else = "run").
_LAUNDRY_PAUSE = {"PAUSE"}
_LAUNDRY_STOP = {"POWER_OFF", "INITIAL", "END", "SLEEP", "ERROR", "RESERVED",
                 "SMART_DIAGNOSIS", "FIRMWARE", "CANCEL", "COMPLETE"}

# robot cleaner runState.currentState -> canonical vacuum.status
_VACUUM_STATUS = {
    "CLEANING": "cleaning", "MACROSECTOR": "cleaning", "MONITORING_DETECTING": "cleaning",
    "PAUSE": "paused", "HOMING": "returning", "CHARGING": "charging",
    "CHARGING_COMPLETE": "docked", "ERROR": "error",
}


def region_for_country(country: str) -> str:
    c = (country or "").upper()
    if c in _KIC:
        return "kic"
    if c in _AIC:
        return "aic"
    return "eic"


def _message_id() -> str:
    return base64.urlsafe_b64encode(uuid.uuid4().bytes)[:-2].decode()


def _loc_blocks(section: Any) -> list[tuple[str | None, dict[str, Any]]]:
    """Normalize profile/state layouts: dict (single unit) or list of
    per-location dicts ({"location": {"locationName": "MAIN"}, ...})."""
    if isinstance(section, dict):
        return [(None, section)]
    out = []
    for blk in section or []:
        if isinstance(blk, dict):
            out.append(((blk.get("location") or {}).get("locationName"), blk))
    return out


def _writable_values(prop: Any) -> list[Any] | None:
    """Profile property -> list of writable enum values, [] if read-only,
    None if the property isn't described at all."""
    if not isinstance(prop, dict):
        return None if prop is None else []
    if "w" not in (prop.get("mode") or []):
        return []
    vals = (prop.get("value") or {}).get("w")
    return list(vals) if isinstance(vals, list) else [True]


class LGThinQAdapter(CloudAdapter):
    id = "lg_thinq"
    name = "LG ThinQ (cloud)"

    def __init__(
        self,
        tokens: TokenProvider | None = None,
        country: str | None = None,
        base_url: str | None = None,
        client_id: str | None = None,
        api_key: str | None = None,
        session: Any = None,
        timeout: float = 15,
    ) -> None:
        self.tokens = tokens or EnvTokenProvider(
            "LG_THINQ_TOKEN",
            hint="Create a Personal Access Token at https://connect-pat.lgthinq.com .",
        )
        self._country = country
        self._base_url = base_url
        self._client_id = client_id
        self._api_key = api_key
        self._session = session
        self.timeout = timeout

    # ----------------------------------------------------------- settings --
    @property
    def country(self) -> str:
        return (self._country or os.environ.get("LG_THINQ_COUNTRY") or "KR").upper()

    @property
    def base_url(self) -> str:
        url = self._base_url or os.environ.get("LG_THINQ_API_BASE")
        return (url or f"https://api-{region_for_country(self.country)}.lgthinq.com").rstrip("/")

    @property
    def client_id(self) -> str:
        if self._client_id:
            return self._client_id
        env = os.environ.get("LG_THINQ_CLIENT_ID")
        if env:
            self._client_id = env
            return env
        # Stable per hub install (LG expects a consistent client id).
        path = config.TOKEN_DIR / "lg_thinq_client_id.txt"
        try:
            self._client_id = path.read_text().strip()
        except OSError:
            self._client_id = ""
        if not self._client_id:
            self._client_id = f"homehub-{uuid.uuid4()}"
            try:
                config.ensure_dirs()
                path.write_text(self._client_id)
            except OSError:
                pass
        return self._client_id

    @property
    def session(self):
        if self._session is None:
            import requests

            self._session = requests.Session()
        return self._session

    # --------------------------------------------------------------- HTTP --
    def headers(self, control: bool = False) -> dict[str, str]:
        h = {
            "Authorization": f"Bearer {self.tokens.get_token()}",
            "x-country": self.country,
            "x-message-id": _message_id(),
            "x-client-id": self.client_id,
            "x-api-key": self._api_key or os.environ.get("LG_THINQ_API_KEY") or DEFAULT_API_KEY,
            "x-service-phase": "OP",
            "Content-Type": "application/json",
        }
        if control:
            h["x-conditional-control"] = "true"
        return h

    def _request(self, method: str, path: str, json: Any = None, control: bool = False) -> Any:
        url = f"{self.base_url}{path}"
        headers = self.headers(control=control)
        try:
            r = self.session.request(method, url, headers=headers, json=json, timeout=self.timeout)
        except Exception as e:  # noqa: BLE001
            raise self._transport_error("LG ThinQ", method, url, e) from e
        body = self._json_or_text(r)
        if 200 <= r.status_code < 300:
            return body.get("response") if isinstance(body, dict) else body
        err = (body.get("error") or {}) if isinstance(body, dict) else {}
        code = str(err.get("code", ""))
        msg = err.get("message", body)
        if code == "2301":   # COMMAND_NOT_SUPPORTED_IN_REMOTE_OFF
            raise RemoteControlDisabledError(
                "LG appliance has remote control turned off. Enable 'Remote Start' on the "
                f"appliance, then retry. ({code}: {msg})"
            )
        if r.status_code in (401, 403) or code in ("1103", "1218", "1302"):
            self.tokens.invalidate()
            raise CloudAuthError(f"LG ThinQ rejected the token ({r.status_code}/{code}): {msg}")
        raise CloudAPIError(f"LG ThinQ {method} {path} -> {r.status_code}/{code}: {msg}",
                            status=r.status_code, code=code or None)

    # ---------------------------------------------------------- discovery --
    def list_devices(self) -> list[Device]:
        out: list[Device] = []
        for item in self._request("GET", "/devices") or []:
            did = item.get("deviceId")
            info = item.get("deviceInfo") or {}
            dtype = info.get("deviceType", "")
            profile: dict[str, Any] = {}
            state: Any = {}
            if dtype in _TYPE_KIND:
                try:
                    profile = self._request("GET", f"/devices/{did}/profile") or {}
                except CloudAuthError:
                    raise
                except Exception:  # noqa: BLE001
                    profile = {}
                try:
                    state = self._request("GET", f"/devices/{did}/state") or {}
                except CloudAuthError:
                    raise
                except Exception:  # noqa: BLE001
                    state = {}
            out.extend(self.devices_from_item(item, profile, state))
        return out

    def devices_from_item(self, item: dict[str, Any], profile: dict[str, Any], state: Any) -> list[Device]:
        did = item["deviceId"]
        info = item.get("deviceInfo") or {}
        dtype = info.get("deviceType", "")
        alias = info.get("alias") or info.get("modelName") or did
        kind = _TYPE_KIND.get(dtype) or _TYPE_KIND_PASSIVE.get(dtype, "unknown")
        base_meta = {
            "cloudId": did,
            "source": "cloud",
            "deviceType": dtype,
            "model": info.get("modelName"),
            "match": {"brand": "LG", "model": info.get("modelName"), "name": alias, "mac": None},
        }
        prop = (profile or {}).get("property", {})

        def mk(dev_id: str, name: str, caps: dict, extra: dict) -> Device:
            return Device(
                id=dev_id, name=name, adapter=self.id, kind=kind, vendor="LG",
                reachable=True, controllable=bool(caps), capabilities=caps,
                meta={**base_meta, **extra},
            )

        if kind in ("washer", "dryer") and dtype in _TYPE_KIND:
            key = cap.WASHER if kind == "washer" else cap.DRYER
            states = _loc_blocks(state)
            profiles = dict(_loc_blocks(prop))
            if not states:
                states = [(loc, {}) for loc in profiles] or [(None, {})]
            devs = []
            for loc, st in states:
                pblk = profiles.get(loc) or profiles.get(None) or {}
                inst = self._laundry_cap(key, kind, st, pblk)
                multi = len(states) > 1
                dev_id = f"{self.id}:{did}" + (f":{loc}" if multi and loc else "")
                name = alias + (f" ({loc})" if multi and loc else "")
                devs.append(mk(dev_id, name, {key: inst}, {"location": loc}))
            return devs

        if kind == "refrigerator" and dtype in _TYPE_KIND:
            return [mk(f"{self.id}:{did}", alias, {cap.REFRIGERATION: self._fridge_cap(state or {}, prop or {})}, {})]

        if kind == "vacuum":
            inst, extra = self._vacuum_cap(state or {}, prop or {})
            return [mk(f"{self.id}:{did}", alias, {cap.VACUUM: inst}, extra)]

        # Unmapped LG device type: show it, but not controllable.
        return [mk(f"{self.id}:{did}", alias, {}, {})]

    # ---------------------------------------------------------- mapping ----
    @staticmethod
    def _laundry_cap(key: str, kind: str, st: dict, pblk: dict) -> cap.CapabilityInstance:
        mode_key = "washerOperationMode" if kind == "washer" else "dryerOperationMode"
        cur = ((st.get("runState") or {}).get("currentState") or "").upper() or None
        if cur in _LAUNDRY_PAUSE:
            machine = "pause"
        elif cur is None or cur in _LAUNDRY_STOP:
            machine = "stop"
        else:
            machine = "run"
        timer = st.get("timer") or {}
        remaining = None
        if "remainHour" in timer or "remainMinute" in timer:
            remaining = int(timer.get("remainHour") or 0) * 60 + int(timer.get("remainMinute") or 0)
        rc = (st.get("remoteControlEnable") or {}).get("remoteControlEnabled")
        writable = _writable_values((pblk.get("operation") or {}).get(mode_key))
        if writable is None:        # profile unavailable -> offer all, device decides
            actions = list(_LAUNDRY_ACTION_VALUE)
        else:
            actions = [a for a, v in _LAUNDRY_ACTION_VALUE.items() if v in writable]
        return cap.CapabilityInstance(key=key, actions=actions, state={
            "machineState": machine,
            "jobState": cur.lower() if cur else None,
            "remainingMinutes": remaining,
            "completionTime": None,
            "remoteControlEnabled": rc if isinstance(rc, bool) else None,
        })

    @staticmethod
    def _fridge_cap(st: dict, prop: dict) -> cap.CapabilityInstance:
        state: dict[str, Any] = {
            "unit": None,
            # ThinQ Connect publishes target temperatures only (no measured value).
            "fridgeTemperature": None, "freezerTemperature": None,
            "fridgeSetpoint": None, "freezerSetpoint": None,
            "doors": {}, "doorOpen": None, "rapidCooling": None, "rapidFreezing": None,
        }
        for blk in st.get("temperatureInUnits") or st.get("temperature") or []:
            loc = (blk.get("locationName") or "").upper()
            unit = (blk.get("unit") or "C").upper()
            v = blk.get(f"targetTemperature{unit}", blk.get("targetTemperature"))
            state["unit"] = state["unit"] or unit
            if loc == "FRIDGE":
                state["fridgeSetpoint"] = v
            elif loc == "FREEZER":
                state["freezerSetpoint"] = v
        for blk in st.get("doorStatus") or []:
            loc = (blk.get("locationName") or "MAIN").lower()
            if blk.get("doorState") is not None:
                state["doors"][loc] = str(blk.get("doorState")).upper() == "OPEN"
        state["doorOpen"] = any(state["doors"].values()) if state["doors"] else None
        refr = st.get("refrigeration") or {}
        rf = refr.get("rapidFreeze", refr.get("expressMode"))
        state["rapidFreezing"] = rf if isinstance(rf, bool) else None
        rc = refr.get("expressFridge")
        state["rapidCooling"] = rc if isinstance(rc, bool) else None
        state["unit"] = state["unit"] or "C"

        actions: list[str] = []
        ptemps = {(b.get("locationName") or "").upper(): b for b in (prop.get("temperatureInUnits") or [])}
        for loc, action, skey in (("FRIDGE", "setFridgeSetpoint", "fridgeSetpoint"),
                                  ("FREEZER", "setFreezerSetpoint", "freezerSetpoint")):
            pb = ptemps.get(loc)
            if pb is not None:
                if any(_writable_values(v) for k, v in pb.items() if k.startswith("targetTemperature")):
                    actions.append(action)
            elif not ptemps and state[skey] is not None:
                actions.append(action)
        prefr = prop.get("refrigeration") or {}
        if prefr:
            if _writable_values(prefr.get("expressFridge")):
                actions.append("setRapidCooling")
            if _writable_values(prefr.get("rapidFreeze")) or _writable_values(prefr.get("expressMode")):
                actions.append("setRapidFreezing")
        else:
            if state["rapidCooling"] is not None:
                actions.append("setRapidCooling")
            if state["rapidFreezing"] is not None:
                actions.append("setRapidFreezing")
        return cap.CapabilityInstance(key=cap.REFRIGERATION, actions=actions, state=state)

    @staticmethod
    def _vacuum_cap(st: dict, prop: dict) -> tuple[cap.CapabilityInstance, dict[str, Any]]:
        cur = ((st.get("runState") or {}).get("currentState") or "").upper()
        batt = st.get("battery") or {}
        pct = batt.get("percent")
        job = (st.get("robotCleanerJobMode") or {}).get("currentJobMode")
        job_prop = (prop.get("robotCleanerJobMode") or {}).get("currentJobMode")
        modes = ((job_prop or {}).get("value") or {}).get("r") if isinstance(job_prop, dict) else None
        writable = _writable_values((prop.get("operation") or {}).get("cleanOperationMode"))
        # ASSUMPTION: cleanOperationMode values START/PAUSE/HOMING/RESUME/WAKE_UP
        # (as used by LG's SDK + Home Assistant's lg_thinq vacuum entity).
        if writable is None:
            actions = ["start", "pause", "dock"]
        else:
            actions = [a for a, v in (("start", "START"), ("pause", "PAUSE"), ("dock", "HOMING")) if v in writable]
        inst = cap.CapabilityInstance(key=cap.VACUUM, actions=actions, state={
            "status": _VACUUM_STATUS.get(cur, "idle"),
            "battery": pct if isinstance(pct, int) else None,
            "cleaningMode": job,
            "cleaningModes": list(modes or []),
        })
        # Vendor details the adapter needs for START vs RESUME/WAKE_UP; kept
        # out of the canonical state on purpose.
        return inst, {"lgRunState": cur or None, "lgCleanOperationWritable": writable}

    # ----------------------------------------------------------- control ---
    def execute(self, device: Device, capability: str, action: str, params: dict[str, Any]) -> dict[str, Any]:
        cap.validate_action(capability, action)
        did = device.meta["cloudId"]
        loc = device.meta.get("location")

        if capability in (cap.WASHER, cap.DRYER):
            mode_key = "washerOperationMode" if capability == cap.WASHER else "dryerOperationMode"
            if action == "start":
                live = self._request("GET", f"/devices/{did}/state") or {}
                blocks = dict(_loc_blocks(live))
                st = blocks.get(loc) or blocks.get(None) or (next(iter(blocks.values())) if blocks else {})
                flag = (st.get("remoteControlEnable") or {}).get("remoteControlEnabled")
                self.require_remote_start(flag if isinstance(flag, bool) else None, device)
            payload: dict[str, Any] = {"operation": {mode_key: _LAUNDRY_ACTION_VALUE[action]}}
            if loc:
                payload = {"location": {"locationName": loc}, **payload}
            return self._control(did, payload)

        if capability == cap.REFRIGERATION:
            if action in ("setFridgeSetpoint", "setFreezerSetpoint"):
                try:
                    t = float(params["temperature"])
                except (KeyError, TypeError, ValueError):
                    raise ValueError("'temperature' must be a number") from None
                t = int(t) if t.is_integer() else t
                inst = device.capabilities.get(cap.REFRIGERATION)
                unit = str(params.get("unit") or (inst.state.get("unit") if inst else None) or "C").upper()
                where = "FRIDGE" if action == "setFridgeSetpoint" else "FREEZER"
                return self._control(did, {"temperatureInUnits": {"locationName": where, f"targetTemperature{unit}": t}})
            enabled = params.get("enabled")
            if not isinstance(enabled, bool):
                raise ValueError("'enabled' must be true or false")
            # ASSUMPTION: expressFridge = "Express Cool" (fridge), rapidFreeze =
            # "Express Freeze"; older models expose expressMode instead of rapidFreeze.
            if action == "setRapidCooling":
                return self._control(did, {"refrigeration": {"expressFridge": enabled}})
            return self._control(did, {"refrigeration": {"rapidFreeze": enabled}})

        if capability == cap.VACUUM:
            inst = device.capabilities.get(cap.VACUUM)
            status = inst.state.get("status") if inst else None
            run_state = (device.meta.get("lgRunState") or "").upper()
            writable = device.meta.get("lgCleanOperationWritable") or []
            value = {"start": "START", "pause": "PAUSE", "dock": "HOMING"}.get(action)
            if value is None:
                raise ValueError(f"LG robot cleaners do not support vacuum.{action}")
            if action == "start":
                if run_state == "SLEEP" and "WAKE_UP" in writable:
                    value = "WAKE_UP"
                elif status == "paused" and "RESUME" in writable:
                    value = "RESUME"
            return self._control(did, {"operation": {"cleanOperationMode": value}})

        raise ValueError(f"unsupported: {capability}.{action}")

    def _control(self, did: str, payload: dict[str, Any]) -> dict[str, Any]:
        resp = self._request("POST", f"/devices/{did}/control", json=payload, control=True)
        return {"ok": True, "method": "lg_thinq", "payload": payload, "response": resp}

    # ----------------------------------------------------------- refresh ---
    def refresh_state(self, device: Device) -> None:
        did = device.meta["cloudId"]
        item = {"deviceId": did, "deviceInfo": {"deviceType": device.meta.get("deviceType"),
                                                "alias": device.name, "modelName": device.meta.get("model")}}
        profile = self._request("GET", f"/devices/{did}/profile") or {}
        state = self._request("GET", f"/devices/{did}/state") or {}
        for fresh in self.devices_from_item(item, profile, state):
            if fresh.id == device.id or fresh.meta.get("location") == device.meta.get("location"):
                for k, inst in fresh.capabilities.items():
                    if k in device.capabilities:
                        device.capabilities[k].state = inst.state
                        device.capabilities[k].actions = inst.actions
                for mk_ in ("lgRunState", "lgCleanOperationWritable"):
                    if mk_ in fresh.meta:
                        device.meta[mk_] = fresh.meta[mk_]
                break
        device.reachable = True
