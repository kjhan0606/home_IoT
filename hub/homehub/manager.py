"""DeviceManager: the hub's control plane.

Owns the current device set, runs discovery, persists snapshots, and routes
canonical (capability, action) commands to the owning adapter singleton.
"""
from __future__ import annotations

import threading
from typing import Any

from . import store
from .adapters import registry
from .discovery import engine
from .models import Device


class DeviceManager:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._devices: dict[str, Device] = {d.id: d for d in store.load_devices()}
        self._scanning = False

    # --- queries --------------------------------------------------------------
    def list_devices(self) -> list[Device]:
        with self._lock:
            return list(self._devices.values())

    def get(self, device_id: str) -> Device | None:
        with self._lock:
            return self._devices.get(device_id)

    @property
    def scanning(self) -> bool:
        return self._scanning

    # --- discovery ------------------------------------------------------------
    def scan(self, **kwargs: Any) -> list[Device]:
        self._scanning = True
        try:
            hosts = engine.scan(**kwargs)
            fresh = registry.build_devices(hosts)
            with self._lock:
                merged: dict[str, Device] = {}
                for dev in fresh:
                    prev = self._devices.get(dev.id)
                    if prev:  # preserve token refs / learned metadata
                        for k, v in prev.meta.items():
                            dev.meta.setdefault(k, v)
                    merged[dev.id] = dev
                self._devices = merged
            store.save_devices(fresh)
            return fresh
        finally:
            self._scanning = False

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
        return adapter.execute(dev, capability, action, params)

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
        return dev
