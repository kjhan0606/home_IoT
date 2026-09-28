"""DeviceManager: the hub's control plane.

Owns the current device set, runs discovery (LAN scan + enabled cloud
adapters), links duplicates (``linking.py``), persists snapshots, and routes
canonical (capability, action) commands to the owning adapter — falling back to
a linked cloud adapter when the local path fails or lacks the action.
"""
from __future__ import annotations

import threading
from typing import Any

from . import linking, store
from .adapters import registry
from .discovery import engine
from .models import Device


class DeviceManager:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._devices: dict[str, Device] = {d.id: d for d in store.load_devices()}
        lan, cloud = store.load_sources()
        # Old snapshots (pre-cloud) only have the merged list == LAN devices.
        self._lan: list[Device] = lan if lan is not None else list(self._devices.values())
        self._cloud: dict[str, list[Device]] = {}
        for d in cloud or []:
            self._cloud.setdefault(d.adapter, []).append(d)
        self._aliases: dict[str, str] = {}
        self.cloud_errors: dict[str, str] = {}
        self._scanning = False

    # --- queries --------------------------------------------------------------
    def list_devices(self) -> list[Device]:
        with self._lock:
            return list(self._devices.values())

    def get(self, device_id: str) -> Device | None:
        with self._lock:
            dev = self._devices.get(device_id)
            if dev is None and device_id in self._aliases:
                dev = self._devices.get(self._aliases[device_id])
            return dev

    @property
    def scanning(self) -> bool:
        return self._scanning

    # --- discovery ------------------------------------------------------------
    def scan(self, lan: bool = True, cloud: bool = True, **kwargs: Any) -> list[Device]:
        self._scanning = True
        try:
            if lan:
                hosts = engine.scan(**kwargs)
                fresh_lan = registry.build_devices(hosts)
                prev = {d.id: d for d in self._lan}
                for dev in fresh_lan:
                    p = prev.get(dev.id)
                    if p:  # preserve token refs / learned metadata
                        for k, v in p.meta.items():
                            dev.meta.setdefault(k, v)
                self._lan = fresh_lan
            if cloud:
                self.sync_cloud()
            return self._rebuild()
        finally:
            self._scanning = False

    def sync_cloud(self) -> None:
        """Refresh device lists from every enabled cloud adapter. A failing
        vendor keeps its previous device list and reports the error."""
        enabled = {a.id for a in registry.cloud_adapters()}
        for aid in list(self._cloud):
            if aid not in enabled:
                del self._cloud[aid]          # token removed -> drop its devices
        for adapter in registry.cloud_adapters():
            try:
                self._cloud[adapter.id] = adapter.list_devices()
                self.cloud_errors.pop(adapter.id, None)
            except Exception as e:  # noqa: BLE001
                self.cloud_errors[adapter.id] = f"{type(e).__name__}: {e}"

    def _rebuild(self) -> list[Device]:
        cloud_all = [d for devs in self._cloud.values() for d in devs]
        merged, aliases = linking.merge(self._lan, cloud_all)
        with self._lock:
            self._devices = {d.id: d for d in merged}
            self._aliases = aliases
        store.save_devices(merged, lan=self._lan, cloud=cloud_all)
        return merged

    # --- control --------------------------------------------------------------
    def execute(
        self, device_id: str, capability: str, action: str, params: dict[str, Any]
    ) -> dict[str, Any]:
        dev = self.get(device_id)
        if dev is None:
            raise KeyError(f"unknown device: {device_id}")
        if not dev.controllable or dev.adapter == "unknown":
            raise PermissionError(f"device {device_id} is not controllable")
        adapter = registry.get_adapter(dev.adapter)
        if adapter is None:
            raise RuntimeError(f"no adapter '{dev.adapter}' loaded")
        cap_inst = dev.capabilities.get(capability)
        if cap_inst is None or action not in cap_inst.actions:
            raise ValueError(
                f"{device_id} does not support {capability}.{action}"
            )

        fb = dev.meta.get("fallback")
        primary_caps = dev.meta.get("primaryCapabilities")
        if not fb or primary_caps is None:
            return adapter.execute(dev, capability, action, params)

        fb_adapter = registry.get_adapter(fb["adapter"])
        fb_dev = Device.from_dict(fb["device"])
        fb_inst = fb_dev.capabilities.get(capability)
        fb_ok = (
            fb_adapter is not None
            and getattr(fb_adapter, "enabled", lambda: True)()
            and fb_inst is not None
            and action in fb_inst.actions
        )
        if action in primary_caps.get(capability, []):
            try:
                return adapter.execute(dev, capability, action, params)
            except (ValueError, PermissionError):
                raise
            except Exception as e:  # noqa: BLE001 - transport failure -> cloud
                if not fb_ok:
                    raise
                res = fb_adapter.execute(fb_dev, capability, action, params)
                return {**res, "via": fb["adapter"], "primaryError": str(e)}
        if fb_ok:
            res = fb_adapter.execute(fb_dev, capability, action, params)
            return {**res, "via": fb["adapter"]}
        raise RuntimeError(f"no available backend for {capability}.{action}")

    def get_map(self, device_id: str) -> tuple[bytes | None, dict[str, Any]]:
        """Fetch a rendered map from whichever linked backend provides one."""
        from . import capabilities as cap

        dev = self.get(device_id)
        if dev is None:
            raise KeyError(f"unknown device: {device_id}")
        candidates = [(registry.get_adapter(dev.adapter), dev)]
        fb = dev.meta.get("fallback")
        if fb:
            candidates.append((registry.get_adapter(fb["adapter"]), Device.from_dict(fb["device"])))
        for adapter, d in candidates:
            if adapter is not None and hasattr(adapter, "get_map") and cap.VACUUM_MAP in d.capabilities:
                return adapter.get_map(d)
        raise LookupError(f"device {device_id} has no map")

    def cached_map(self, device_id: str) -> tuple[bytes | None, dict[str, Any]] | None:
        dev = self.get(device_id)
        if dev is None:
            return None
        for aid in (dev.adapter, (dev.meta.get("fallback") or {}).get("adapter")):
            adapter = registry.get_adapter(aid) if aid else None
            if adapter is not None and hasattr(adapter, "cached_map"):
                did = dev.id if aid == dev.adapter else dev.meta["fallback"]["id"]
                hit = adapter.cached_map(Device(id=did, name="", adapter=aid))
                if hit:
                    return hit
        return None

    def refresh(self, device_id: str) -> Device | None:
        dev = self.get(device_id)
        if dev is None:
            return None
        adapter = registry.get_adapter(dev.adapter)
        if adapter is not None:
            try:
                adapter.refresh_state(dev)
            except Exception:
                pass
        fb = dev.meta.get("fallback")
        fb_adapter = registry.get_adapter(fb["adapter"]) if fb else None
        if fb and fb_adapter is not None and getattr(fb_adapter, "enabled", lambda: True)():
            try:
                fb_dev = Device.from_dict(fb["device"])
                fb_adapter.refresh_state(fb_dev)
                fb["device"] = fb_dev.to_dict()
                owned = dev.meta.get("primaryCapabilities") or {}
                for key, inst in fb_dev.capabilities.items():
                    if key in dev.capabilities and key not in owned:
                        dev.capabilities[key].state = dict(inst.state)
            except Exception:
                pass
        return dev
