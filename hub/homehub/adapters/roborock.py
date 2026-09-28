"""Roborock robot-vacuum adapter (unofficial API via ``python-roborock``).

Link flow (one-time, via hub endpoints):
  POST /integrations/roborock/request-code {email}         -> e-mail with a code
  POST /integrations/roborock/login {email, code|password} -> tokens + local keys
      stored in hub/data/tokens/roborock.json (0600), never logged/returned
  POST /integrations/roborock/unlink                       -> forget everything

Afterwards devices come from the account (like the other cloud adapters) but
commands go over the **local LAN when reachable, else cloud MQTT** (library
policy, see cloud/roborock_backend.py). LAN-discovered Roborock hosts are
linked to these devices by MAC/IP in ``linking.py``.

Canonical mapping (V1-protocol vacuums: S5/S6/S7/S8/Q5/Q7-max/Qrevo…):
  vacuum         start/pause/stop/dock, status, battery, error, dockError
  roomCleaning   app_segment_clean [{"segments": [ids], "repeat": n}]
  zoneCleaning   app_zoned_clean [[x1, y1, x2, y2, repeat], ...]  (max 5 zones)
  goTo           app_goto_target [x, y]
  fanSpeed       set_custom_mode [code]            (levels from the model's features)
  mopping        set_water_box_custom_mode [code] / set_mop_mode [code]
  consumables    reset_consumable [attr]
  cleaningStats  status clean_area / clean_time
  vacuumMap      GET /devices/{id}/map  (PNG + rooms/robot/dock + transform)
Newer B01/A01-protocol devices (Q7/Q10 B01, Zeo, Dyad) are listed but not controllable yet.
"""
from __future__ import annotations

import datetime as _dt
import threading
from typing import Any

from .. import capabilities as cap
from .. import config, secret_store
from ..cloud.auth import TokenProvider
from ..cloud.errors import CloudAPIError, CloudNotConfiguredError
from ..cloud.roborock_backend import CONSUMABLE_LIFETIME, LibraryBackend, RoborockBackend
from ..models import Device
from ..vacuum_map import build_metadata
from .cloud_base import CloudAdapter

SECRET = "roborock"
MAX_REPEAT = 3
MAX_ZONES = 5

_STATUS = {
    "paused": "paused",
    "returning_home": "returning", "docking": "returning", "going_to_wash_the_mop": "returning",
    "back_to_dock_washing_duster": "returning",
    "charging": "charging",
    "charging_complete": "docked", "emptying_the_bin": "docked", "washing_the_mop": "docked",
    "washing_the_mop_2": "docked", "air_drying_stopping": "docked",
    "going_to_target": "moving",
    "error": "error", "charging_problem": "error",
    "idle": "idle", "charger_disconnected": "idle", "device_offline": "idle", "unknown": "idle",
    "shutting_down": "idle", "updating": "idle", "locked": "idle", "in_call": "idle",
}
_CLEANING_HINTS = ("clean", "mopping", "starting", "mapping", "manual_mode", "remote_control", "patrol")

_CONSUMABLES = [
    # id, label, snapshot field, resettable
    ("mainBrush", "Main brush", "main_brush_work_time", True),
    ("sideBrush", "Side brush", "side_brush_work_time", True),
    ("filter", "Filter", "filter_work_time", True),
    ("sensors", "Sensors", "sensor_dirty_time", True),
    ("mopRoller", "Mop roller", "moproller_work_time", False),
]


class LinkError(ValueError):
    """User-fixable link problem (bad code, unknown account, ...) -> HTTP 400."""


class LinkRateLimited(CloudAPIError):
    """Roborock throttled code/login requests -> HTTP 429."""


class _SecretTokens(TokenProvider):
    def available(self) -> bool:
        return bool((secret_store.load(SECRET) or {}).get("user_data"))

    def get_token(self) -> str:  # not a bearer API; presence == linked
        if not self.available():
            raise CloudNotConfiguredError("Roborock account not linked: POST /integrations/roborock/login")
        return "linked"


def _mask(email: str) -> str:
    user, _, dom = email.partition("@")
    return (user[:1] + "***@" + dom) if dom else "***"


def _vac_status(state: str | None) -> str:
    s = (state or "unknown").lower()
    if s in _STATUS:
        return _STATUS[s]
    return "cleaning" if any(h in s for h in _CLEANING_HINTS) else "idle"


def _translate_link_error(e: Exception) -> Exception:
    name = type(e).__name__
    if name in ("RoborockRateLimit", "RoborockTooFrequentCodeRequests"):
        return LinkRateLimited(f"Roborock rate limit: {e}", status=429)
    if name in ("RoborockInvalidCode", "RoborockAccountDoesNotExist", "RoborockInvalidCredentials",
                "RoborockNoUserAgreement", "RoborockInvalidUserAgreement", "RoborockMissingParameters",
                "RoborockInvalidEmail"):
        return LinkError(str(e))
    return CloudAPIError(f"Roborock login failed: {name}: {e}")


class RoborockAdapter(CloudAdapter):
    id = "roborock"
    name = "Roborock (local + cloud, unofficial)"

    def __init__(self, backend: RoborockBackend | None = None) -> None:
        self.tokens = _SecretTokens()
        self._backend = backend
        self._lock = threading.Lock()
        self._maps: dict[str, tuple[bytes | None, dict[str, Any]]] = {}

    @property
    def backend(self) -> RoborockBackend:
        if self._backend is None:
            self._backend = LibraryBackend(cache_path=config.TOKEN_DIR / "roborock_cache.bin")
        return self._backend

    # ------------------------------------------------------------ link flow --
    def link_status(self) -> dict[str, Any]:
        creds = secret_store.load(SECRET) or {}
        return {
            "linked": bool(creds.get("user_data")),
            "account": _mask(creds["username"]) if creds.get("username") else None,
            "linkedAt": creds.get("linkedAt"),
            "devices": creds.get("devices", []),
        }

    def request_code(self, email: str) -> dict[str, Any]:
        email = _clean_email(email)
        try:
            self.backend.request_code(email)
        except Exception as e:  # noqa: BLE001
            raise _translate_link_error(e) from None
        return {"ok": True, "sentTo": _mask(email)}

    def login(self, email: str, code: str | None = None, password: str | None = None) -> dict[str, Any]:
        email = _clean_email(email)
        if bool(code) == bool(password):
            raise LinkError("provide exactly one of 'code' or 'password'")
        if code is not None:
            code = str(code).strip()
            if not code.isdigit():
                raise LinkError("verification code must be digits")
        try:
            res = self.backend.login(email, code=code, password=password)
        except Exception as e:  # noqa: BLE001
            raise _translate_link_error(e) from None
        devices = [{"name": d.get("name"), "model": d.get("model")} for d in res.get("devices", [])]
        secret_store.save(SECRET, {
            "username": email,
            "user_data": res["user_data"],
            "base_url": res.get("base_url"),
            "local_keys": res.get("local_keys", {}),
            "devices": devices,
            "linkedAt": _dt.datetime.now(_dt.timezone.utc).isoformat(timespec="seconds"),
        })
        return {"linked": True, "account": _mask(email), "devices": devices}

    def unlink(self) -> dict[str, Any]:
        try:
            self.backend.close()
        finally:
            removed = secret_store.delete(SECRET)
            try:
                (config.TOKEN_DIR / "roborock_cache.bin").unlink()
            except OSError:
                pass
            self._maps.clear()
        return {"linked": False, "removed": removed}

    def close(self) -> None:
        if self._backend is not None:
            self._backend.close()

    # ------------------------------------------------------------ discovery --
    def _connect(self) -> None:
        creds = secret_store.load(SECRET)
        if not creds or not creds.get("user_data"):
            raise CloudNotConfiguredError("Roborock account not linked: POST /integrations/roborock/login")
        self.backend.connect(creds)

    def list_devices(self) -> list[Device]:
        with self._lock:
            self._connect()
            return [self.device_from_snapshot(s) for s in self.backend.snapshots()]

    def device_from_snapshot(self, s: dict[str, Any]) -> Device:
        duid = s["duid"]
        caps: dict[str, cap.CapabilityInstance] = {}
        meta: dict[str, Any] = {
            "cloudId": duid,
            "source": "cloud",
            "model": s.get("model"),
            "productName": s.get("productName"),
            "protocol": s.get("protocol"),
            "transport": s.get("transport"),
            "match": {"brand": "Roborock", "model": s.get("model"), "name": s.get("name"),
                      "mac": s.get("mac"), "ip": s.get("ip")},
        }
        if s.get("protocol") == "v1":
            caps, extra = self._caps_from_snapshot(s)
            meta.update(extra)
        else:
            meta["note"] = "protocol not supported by the hub yet (listed only)"
        return Device(
            id=f"{self.id}:{duid}", name=s.get("name") or duid, adapter=self.id, kind="vacuum",
            ip=s.get("ip"), mac=s.get("mac"), vendor="Roborock",
            reachable=bool(s.get("online", True)), controllable=bool(caps), capabilities=caps, meta=meta,
        )

    @staticmethod
    def _caps_from_snapshot(s: dict[str, Any]) -> tuple[dict[str, cap.CapabilityInstance], dict[str, Any]]:
        st = s.get("status") or {}
        opts = s.get("options") or {}
        feats = s.get("features") or {}
        C = cap.CapabilityInstance
        caps = {
            cap.VACUUM: C(cap.VACUUM, ["start", "pause", "stop", "dock"], {
                "status": _vac_status(st.get("state")),
                "battery": st.get("battery"),
                "cleaningMode": None, "cleaningModes": [],
                "error": st.get("error"), "dockError": st.get("dockError"),
            }),
            cap.CLEANING_STATS: C(cap.CLEANING_STATS, [], {
                "areaM2": st.get("cleanAreaM2"), "durationSeconds": st.get("cleanTimeS"),
            }),
        }
        rooms = s.get("rooms") or []
        if feats.get("rooms") and rooms:
            caps[cap.ROOM_CLEANING] = C(cap.ROOM_CLEANING, ["cleanRooms"], {"rooms": rooms, "maxRepeat": MAX_REPEAT})
        if feats.get("zones"):
            caps[cap.ZONE_CLEANING] = C(cap.ZONE_CLEANING, ["cleanZones"], {
                "maxZones": MAX_ZONES, "maxRepeat": MAX_REPEAT, "coordinateSpace": "map"})
        if feats.get("goto"):
            caps[cap.GO_TO] = C(cap.GO_TO, ["goTo"], {"coordinateSpace": "map"})
        if opts.get("fanSpeeds"):
            caps[cap.FAN_SPEED] = C(cap.FAN_SPEED, ["setLevel"], {
                "level": st.get("fanSpeed"), "levels": list(opts["fanSpeeds"])})
        mop_actions = (["setWaterLevel"] if opts.get("waterLevels") else []) + \
                      (["setMopMode"] if opts.get("mopModes") else [])
        if mop_actions:
            caps[cap.MOPPING] = C(cap.MOPPING, mop_actions, {
                "waterLevel": st.get("waterLevel"), "waterLevels": list(opts.get("waterLevels") or {}),
                "mopMode": st.get("mopMode"), "mopModes": list(opts.get("mopModes") or {}),
            })
        cons = s.get("consumables") or {}
        items = []
        for cid, label, field, resettable in _CONSUMABLES:
            used = cons.get(field)
            if used is None:
                continue
            life = CONSUMABLE_LIFETIME[field]
            items.append({"id": cid, "name": label, "usedHours": round(used / 3600, 1),
                          "remainingPercent": max(0, round(100 - used * 100 / life)), "resettable": resettable})
        if items:
            reset = ["reset"] if any(i["resettable"] for i in items) else []
            caps[cap.CONSUMABLES] = C(cap.CONSUMABLES, reset, {"items": items})
        if feats.get("map"):
            caps[cap.VACUUM_MAP] = C(cap.VACUUM_MAP, [], {"available": True})
        # Vendor codes the adapter needs to translate canonical names -> commands.
        extra = {"rrOptions": opts, "rrInCleaning": st.get("inCleaning"), "rrState": st.get("state")}
        return caps, extra

    # -------------------------------------------------------------- control --
    def execute(self, device: Device, capability: str, action: str, params: dict[str, Any]) -> dict[str, Any]:
        cap.validate_action(capability, action)
        inst = device.capabilities.get(capability)
        if inst is None or action not in inst.actions:
            raise ValueError(f"{device.name} ({device.meta.get('model')}) does not support {capability}.{action}")
        method, args = self.translate(device, capability, action, params or {})
        with self._lock:
            self._connect()
            res = self.backend.send(device.meta["cloudId"], method, args)
        return {"ok": True, "method": "roborock", "command": method, "params": args,
                "transport": res.get("transport"), "response": res.get("result")}

    @staticmethod
    def translate(device: Device, capability: str, action: str, params: dict[str, Any]) -> tuple[str, Any]:
        opts = device.meta.get("rrOptions") or {}
        if capability == cap.VACUUM:
            if action == "start":
                status = (device.capabilities[cap.VACUUM].state or {}).get("status")
                ic = device.meta.get("rrInCleaning")
                if status == "paused" and ic == 2:
                    return "resume_zoned_clean", None
                if status == "paused" and ic == 3:
                    return "resume_segment_clean", None
                return "app_start", None
            return {"pause": "app_pause", "stop": "app_stop", "dock": "app_charge"}[action], None

        if capability == cap.ROOM_CLEANING:
            known = {r["id"] for r in device.capabilities[cap.ROOM_CLEANING].state.get("rooms", [])}
            ids = params.get("roomIds")
            if not isinstance(ids, list) or not ids:
                raise ValueError("'roomIds' must be a non-empty list")
            ids = [str(i) for i in ids]
            unknown = [i for i in ids if i not in known]
            if unknown:
                raise ValueError(f"unknown room ids {unknown}; known: {sorted(known)}")
            # ASSUMPTION: "repeat" key accepted alongside "segments" (Roborock app payload).
            return "app_segment_clean", [{"segments": [int(i) for i in ids], "repeat": _repeat(params)}]

        if capability == cap.ZONE_CLEANING:
            zones = params.get("zones")
            if not isinstance(zones, list) or not zones:
                raise ValueError("'zones' must be a non-empty list of [x1, y1, x2, y2]")
            if len(zones) > MAX_ZONES:
                raise ValueError(f"at most {MAX_ZONES} zones")
            rep = _repeat(params)
            out = []
            for z in zones:
                if not isinstance(z, (list, tuple)) or len(z) != 4:
                    raise ValueError("each zone must be [x1, y1, x2, y2]")
                x1, y1, x2, y2 = (_int(v, "zone coordinate") for v in z)
                if x1 == x2 or y1 == y2:
                    raise ValueError("zone must have non-zero width and height")
                out.append([min(x1, x2), min(y1, y2), max(x1, x2), max(y1, y2), rep])
            return "app_zoned_clean", out

        if capability == cap.GO_TO:
            return "app_goto_target", [_int(params.get("x"), "x"), _int(params.get("y"), "y")]

        if capability == cap.FAN_SPEED:
            return "set_custom_mode", [_code(opts.get("fanSpeeds"), params.get("level"), "level")]

        if capability == cap.MOPPING:
            if action == "setWaterLevel":
                return "set_water_box_custom_mode", [_code(opts.get("waterLevels"), params.get("level"), "level")]
            return "set_mop_mode", [_code(opts.get("mopModes"), params.get("mode"), "mode")]

        if capability == cap.CONSUMABLES:
            cid = params.get("id")
            row = next((c for c in _CONSUMABLES if c[0] == cid), None)
            items = {i["id"]: i for i in device.capabilities[cap.CONSUMABLES].state.get("items", [])}
            if row is None or cid not in items:
                raise ValueError(f"unknown consumable {cid!r}; known: {sorted(items)}")
            if not row[3]:
                raise ValueError(f"consumable {cid!r} cannot be reset remotely")
            return "reset_consumable", [row[2]]

        raise ValueError(f"unsupported: {capability}.{action}")

    # -------------------------------------------------------------- refresh --
    def refresh_state(self, device: Device) -> None:
        with self._lock:
            self._connect()
            snap = self.backend.snapshot(device.meta["cloudId"])
        if not snap:
            device.reachable = False
            return
        fresh = self.device_from_snapshot(snap)
        device.capabilities = fresh.capabilities
        for k in ("rrOptions", "rrInCleaning", "rrState", "transport"):
            device.meta[k] = fresh.meta.get(k)
        device.reachable = fresh.reachable

    # ------------------------------------------------------------------ map --
    def get_map(self, device: Device) -> tuple[bytes | None, dict[str, Any]]:
        if cap.VACUUM_MAP not in device.capabilities:
            raise ValueError(f"{device.name} does not provide a map")
        with self._lock:
            self._connect()
            png, raw = self.backend.get_map(device.meta["cloudId"])
        if not raw.get("calibration"):
            raise RuntimeError("map has no calibration points (empty map)")
        meta = build_metadata(raw["calibration"], raw.get("rooms", []), raw.get("robot"),
                              raw.get("dock"), png, raw.get("map_name"))
        self._maps[device.id] = (png, meta)
        return png, meta

    def cached_map(self, device: Device) -> tuple[bytes | None, dict[str, Any]] | None:
        return self._maps.get(device.id)


# ---------------------------------------------------------------- helpers --
def _clean_email(email: Any) -> str:
    e = str(email or "").strip()
    if "@" not in e or len(e) > 254:
        raise LinkError("a valid 'email' is required")
    return e


def _int(v: Any, name: str) -> int:
    try:
        f = float(v)
    except (TypeError, ValueError):
        raise ValueError(f"'{name}' must be a number") from None
    return int(round(f))


def _repeat(params: dict[str, Any]) -> int:
    r = params.get("repeat", 1)
    try:
        r = int(r)
    except (TypeError, ValueError):
        raise ValueError("'repeat' must be an integer") from None
    if not 1 <= r <= MAX_REPEAT:
        raise ValueError(f"'repeat' must be 1..{MAX_REPEAT}")
    return r


def _code(mapping: dict[str, int] | None, name: Any, what: str) -> int:
    mapping = mapping or {}
    if name not in mapping:
        raise ValueError(f"unsupported {what} {name!r} for this model; options: {list(mapping)}")
    return int(mapping[name])
