"""Roborock transport backend (wraps the open-source ``python-roborock`` lib).

The adapter (``adapters/roborock.py``) talks only to the small synchronous
``RoborockBackend`` interface below and works with plain-dict *snapshots*.
This keeps the brand logic testable and isolates us from library API churn
(the library is unofficial and changes often — pinned in requirements.txt).

``LibraryBackend`` runs the asyncio-based library on a private event-loop
thread. Transport policy comes from the library's V1 channel: every command
goes over the **local LAN (TCP 58867, encrypted with the per-device local key)
when connected, falling back to the Roborock cloud MQTT broker** otherwise
(``RpcChannel`` tries the strategies in order). Maps are cloud-only (the
library fetches them over MQTT).

Secrets (``rriot`` tokens in UserData, local keys) are never logged here.
"""
from __future__ import annotations

import asyncio
import logging
import threading
from abc import ABC, abstractmethod
from pathlib import Path
from typing import Any

_LOGGER = logging.getLogger(__name__)

# Seconds -> 100% life (constants from python-roborock roborock/const.py).
CONSUMABLE_LIFETIME = {
    "main_brush_work_time": 1080000,
    "side_brush_work_time": 720000,
    "filter_work_time": 540000,
    "sensor_dirty_time": 108000,
    "moproller_work_time": 1080000,
}


class RoborockBackend(ABC):
    """Synchronous facade the adapter uses. All methods may raise."""

    @abstractmethod
    def request_code(self, email: str) -> None: ...

    @abstractmethod
    def login(self, email: str, code: str | None = None, password: str | None = None) -> dict[str, Any]:
        """Return {"user_data": dict, "base_url": str|None,
        "local_keys": {duid: key}, "devices": [{"duid", "name", "model"}]}."""

    @abstractmethod
    def connect(self, creds: dict[str, Any]) -> None: ...

    @abstractmethod
    def snapshots(self) -> list[dict[str, Any]]: ...

    def snapshot(self, duid: str) -> dict[str, Any] | None:
        return next((s for s in self.snapshots() if s.get("duid") == duid), None)

    @abstractmethod
    def send(self, duid: str, method: str, params: Any = None) -> dict[str, Any]:
        """Return {"result": Any, "transport": "local"|"cloud"}."""

    @abstractmethod
    def get_map(self, duid: str) -> tuple[bytes | None, dict[str, Any]]:
        """Return (png, {"calibration", "rooms", "robot", "dock", "map_name"})."""

    def close(self) -> None:
        return None


class AsyncRunner:
    """A private asyncio loop on a daemon thread; run coroutines synchronously."""

    def __init__(self) -> None:
        self._loop: asyncio.AbstractEventLoop | None = None
        self._lock = threading.Lock()

    def _ensure(self) -> asyncio.AbstractEventLoop:
        with self._lock:
            if self._loop is None or self._loop.is_closed():
                loop = asyncio.new_event_loop()
                t = threading.Thread(target=loop.run_forever, name="roborock-loop", daemon=True)
                t.start()
                self._loop = loop
            return self._loop

    def run(self, coro: Any, timeout: float = 90) -> Any:
        fut = asyncio.run_coroutine_threadsafe(coro, self._ensure())
        return fut.result(timeout)

    def stop(self) -> None:
        with self._lock:
            if self._loop is not None:
                self._loop.call_soon_threadsafe(self._loop.stop)
                self._loop = None


def _enum_name(v: Any) -> str | None:
    if v is None:
        return None
    name = getattr(v, "name", None)
    return str(name if name is not None else v)


def _err_name(v: Any) -> str | None:
    n = _enum_name(v)
    return None if n in (None, "none", "0", "ok") else n


async def _try(coro: Any) -> bool:
    try:
        await coro
        return True
    except Exception as e:  # noqa: BLE001 - one trait failing must not hide the device
        _LOGGER.debug("roborock trait refresh failed: %s", type(e).__name__)
        return False


async def build_snapshot(dev: Any) -> dict[str, Any]:
    """Library RoborockDevice -> plain snapshot dict (duck-typed; tested with fakes)."""
    product = getattr(dev, "product", None)
    info = getattr(dev, "device_info", None)
    connected = bool(getattr(dev, "is_connected", False))
    snap: dict[str, Any] = {
        "duid": dev.duid,
        "name": dev.name,
        "model": getattr(product, "model", None),
        "productName": getattr(product, "name", None),
        "online": getattr(info, "online", None),
        "transport": ("local" if getattr(dev, "is_local_connected", False) else "cloud") if connected else None,
    }
    v1 = getattr(dev, "v1_properties", None)
    if v1 is None:
        snap["protocol"] = "other"
        return snap
    snap["protocol"] = "v1"
    await _try(v1.status.refresh())
    await _try(v1.consumables.refresh())
    await _try(v1.rooms.refresh())
    await _try(v1.network_info.refresh())
    st = v1.status
    feats = getattr(v1, "device_features", None)
    snap["status"] = {
        "state": _enum_name(st.state),
        "battery": st.battery,
        "error": _err_name(st.error_code),
        "dockError": _err_name(getattr(st, "dock_error_status", None)),
        "cleanAreaM2": getattr(st, "square_meter_clean_area", None),
        "cleanTimeS": st.clean_time,
        "fanSpeed": getattr(st, "fan_speed_name", None),
        "waterLevel": getattr(st, "water_mode_name", None),
        "mopMode": getattr(st, "mop_route_name", None),
        "inCleaning": int(st.in_cleaning) if st.in_cleaning is not None else None,
    }

    def opts(options: Any, label: str = "value") -> dict[str, int]:
        out: dict[str, int] = {}
        for o in options or []:
            name = getattr(o, label, None) or getattr(o, "value", None)
            if name is not None and name not in out:
                out[str(name)] = int(o.code)
        return out

    water_ok = getattr(feats, "is_support_water_mode", True) if feats is not None else True
    snap["options"] = {
        "fanSpeeds": opts(_safe(lambda: st.fan_speed_options)),
        "waterLevels": opts(_safe(lambda: st.water_mode_options)) if water_ok else {},
        "mopModes": {v: k for k, v in (_safe(lambda: st.mop_route_mapping) or {}).items()},
    }
    snap["rooms"] = [{"id": str(r.segment_id), "name": r.name} for r in (v1.rooms.rooms or [])]
    snap["consumables"] = {k: getattr(v1.consumables, k, None) for k in CONSUMABLE_LIFETIME}
    snap["ip"] = getattr(v1.network_info, "ip", None)
    snap["mac"] = getattr(v1.network_info, "mac", None)
    # All V1 map-capable vacuums accept app_zoned_clean / app_goto_target /
    # app_segment_clean (ASSUMPTION: very old models without a map don't).
    mp = getattr(st, "map_present", None)
    has_map = bool(snap["rooms"]) or mp is None or bool(mp)
    snap["features"] = {"rooms": bool(snap["rooms"]), "zones": has_map, "goto": has_map, "map": has_map}
    return snap


def _safe(fn: Any) -> Any:
    try:
        return fn()
    except Exception:  # noqa: BLE001
        return None


def map_payload(map_data: Any, room_names: dict[int, str]) -> dict[str, Any]:
    """vacuum_map_parser MapData -> backend map payload (robot coordinates).

    Note the library's naming: calibration()["vacuum"] = robot coords,
    calibration()["map"] = image pixel coords."""
    calib = [{"map": dict(c["vacuum"]), "image": dict(c["map"])} for c in (map_data.calibration() or [])]
    rooms = []
    for number, room in sorted((map_data.rooms or {}).items()):
        rooms.append({"id": str(number), "name": room_names.get(int(number)) or room.name or f"Room {number}",
                      "x0": room.x0, "y0": room.y0, "x1": room.x1, "y1": room.y1})
    vp, ch = map_data.vacuum_position, map_data.charger
    return {
        "calibration": calib,
        "rooms": rooms,
        "robot": None if vp is None else {"x": vp.x, "y": vp.y, "angle": vp.a},
        "dock": None if ch is None else {"x": ch.x, "y": ch.y},
        "map_name": getattr(map_data, "map_name", None),
    }


class LibraryBackend(RoborockBackend):
    def __init__(self, cache_path: Path | None = None) -> None:
        self._runner = AsyncRunner()
        self._pending: dict[str, Any] = {}      # email -> RoborockApiClient (between code + login)
        self._manager: Any = None
        self._cache: Any = None
        self._creds_key: str | None = None
        self._cache_path = cache_path

    # ---------------------------------------------------------- link flow --
    def request_code(self, email: str) -> None:
        from roborock.web_api import RoborockApiClient

        client = RoborockApiClient(username=email)
        self._runner.run(client.request_code_v4())
        self._pending[email.lower()] = client

    def login(self, email: str, code: str | None = None, password: str | None = None) -> dict[str, Any]:
        from roborock.web_api import RoborockApiClient

        client = self._pending.pop(email.lower(), None) or RoborockApiClient(username=email)

        async def _login() -> dict[str, Any]:
            if code is not None:
                user_data = await client.code_login_v4(code)
            else:
                user_data = await client.pass_login(password)
            base_url = await client.base_url
            home = await client.get_home_data_v3(user_data)
            products = {p.id: p for p in home.products}
            devices = list(home.devices) + list(home.received_devices)
            return {
                "user_data": user_data.as_dict(),
                "base_url": base_url,
                "local_keys": {d.duid: d.local_key for d in devices},
                "devices": [{"duid": d.duid, "name": d.name,
                             "model": getattr(products.get(d.product_id), "model", None)} for d in devices],
            }

        return self._runner.run(_login())

    # -------------------------------------------------------------- session --
    def connect(self, creds: dict[str, Any]) -> None:
        key = f"{creds.get('username')}|{(creds.get('user_data') or {}).get('rruid')}"
        if self._manager is not None and key == self._creds_key:
            return
        self.close()
        from roborock.data import UserData
        from roborock.devices.device_manager import UserParams, create_device_manager

        cache = None
        if self._cache_path is not None:
            from roborock.devices.file_cache import FileCache

            from ..secret_store import secure_touch

            secure_touch(self._cache_path)        # 0600 before the lib writes local keys into it
            cache = FileCache(self._cache_path)
        params = UserParams(username=creds["username"], user_data=UserData.from_dict(creds["user_data"]),
                            base_url=creds.get("base_url"))
        self._manager = self._runner.run(create_device_manager(params, cache=cache, prefer_cache=True))
        self._cache = cache
        self._creds_key = key

    def snapshots(self) -> list[dict[str, Any]]:
        if self._manager is None:
            raise RuntimeError("Roborock session not connected")

        async def _all() -> list[dict[str, Any]]:
            devices = await self._manager.discover_devices(prefer_cache=True)
            snaps = [await build_snapshot(d) for d in devices]
            if self._cache is not None:
                await _try(self._cache.flush())
            return snaps

        return self._runner.run(_all(), timeout=120)

    async def _device(self, duid: str) -> Any:
        if self._manager is None:
            raise RuntimeError("Roborock session not connected")
        dev = await self._manager.get_device(duid)
        if dev is None:
            raise RuntimeError(f"Roborock device {duid} not found in account")
        if getattr(dev, "v1_properties", None) is None:
            raise ValueError("this Roborock model uses a protocol the hub does not control yet")
        return dev

    def send(self, duid: str, method: str, params: Any = None) -> dict[str, Any]:
        async def _send() -> dict[str, Any]:
            dev = await self._device(duid)
            transport = "local" if dev.is_local_connected else "cloud"
            # rpc_channel = local first, then MQTT (library RpcChannel strategies).
            result = await dev.v1_properties.command.send(method, params=params)
            return {"result": result, "transport": transport}

        return self._runner.run(_send(), timeout=45)

    def get_map(self, duid: str) -> tuple[bytes | None, dict[str, Any]]:
        async def _map() -> tuple[bytes | None, dict[str, Any]]:
            dev = await self._device(duid)
            v1 = dev.v1_properties
            await v1.map_content.refresh()
            if v1.map_content.map_data is None:
                raise RuntimeError("vacuum returned no map (map saving disabled or not mapped yet)")
            names = {r.segment_id: r.name for r in (v1.rooms.rooms or [])}
            return v1.map_content.image_content, map_payload(v1.map_content.map_data, names)

        return self._runner.run(_map(), timeout=60)

    def close(self) -> None:
        if self._manager is not None:
            try:
                self._runner.run(self._manager.close(), timeout=10)
            except Exception:  # noqa: BLE001
                pass
        self._manager = None
        self._creds_key = None
