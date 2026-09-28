"""DeviceAdapter contract.

An adapter is the *only* thing that knows a device's real protocol. It:
  1. claims discovered hosts it recognizes  (``matches``)
  2. builds a canonical Device with capabilities  (``build_device``)
  3. executes canonical (capability, action) commands  (``execute``)
  4. optionally refreshes live state  (``refresh_state``)

Swapping "local Samsung WS" for "SmartThings cloud" or "Matter controller"
later means writing a new adapter that satisfies this same contract — the
discovery engine, registry, API, and app never change.
"""
from __future__ import annotations

from abc import ABC, abstractmethod
from typing import Any

from ..models import Device, DiscoveredHost


class DeviceAdapter(ABC):
    #: short, stable adapter id, e.g. "samsung_local"
    id: str = "base"
    #: human label
    name: str = "Base Adapter"

    @abstractmethod
    def matches(self, host: DiscoveredHost) -> bool:
        """Return True if this adapter can control the discovered host."""

    @abstractmethod
    def build_device(self, host: DiscoveredHost) -> Device:
        """Create a canonical Device (with capabilities) for a claimed host."""

    @abstractmethod
    def execute(
        self, device: Device, capability: str, action: str, params: dict[str, Any]
    ) -> dict[str, Any]:
        """Run a canonical command. Returns a small result dict.

        Should raise ValueError for bad capability/action/params and
        RuntimeError (or subclass) for transport/device failures.
        """

    def refresh_state(self, device: Device) -> None:
        """Best-effort refresh of ``device.capabilities`` live state. Optional."""
        return None

    # Optional: adapters whose devices expose the ``vacuumMap`` capability
    # implement ``get_map(device) -> (png_bytes, metadata)`` (see vacuum_map.py).
