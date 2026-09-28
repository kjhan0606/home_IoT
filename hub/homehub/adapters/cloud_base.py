"""Base class for cloud-backed adapters.

A cloud adapter still satisfies the ``DeviceAdapter`` contract (build canonical
Devices, execute canonical commands, refresh state) but its devices come from a
vendor account instead of LAN discovery:

  * ``matches()`` is always False — cloud adapters never claim LAN hosts;
  * ``list_devices()`` enumerates the account's devices;
  * ``enabled()`` is False when no credentials are configured, and the manager
    then skips the adapter entirely (the hub runs fine with no tokens).

Linking a cloud device to the same physical device found on the LAN is done
generically in ``homehub/linking.py`` using the hints adapters put in
``Device.meta["match"]`` (brand / model / mac / name).
"""
from __future__ import annotations

from abc import abstractmethod
from typing import Any

from ..cloud.auth import TokenProvider
from ..cloud.errors import CloudAPIError, RemoteControlDisabledError
from ..models import Device, DiscoveredHost
from .base import DeviceAdapter


class CloudAdapter(DeviceAdapter):
    is_cloud: bool = True
    tokens: TokenProvider

    def enabled(self) -> bool:
        return self.tokens.available()

    def matches(self, host: DiscoveredHost) -> bool:  # noqa: ARG002
        return False

    def build_device(self, host: DiscoveredHost) -> Device:  # pragma: no cover
        raise NotImplementedError("cloud adapters build devices from list_devices()")

    @abstractmethod
    def list_devices(self) -> list[Device]:
        """Enumerate the account's devices as canonical Devices (with state)."""

    # -- shared helpers ------------------------------------------------------
    @staticmethod
    def require_remote_start(enabled: bool | None, device: Device) -> None:
        """Vendor safety rule: laundry only starts remotely after the user
        pressed "Remote Start" on the machine. ``None`` = not reported -> allow
        and let the vendor decide."""
        if enabled is False:
            raise RemoteControlDisabledError(
                f"Remote control is disabled on '{device.name}'. Enable 'Remote "
                "Start' on the appliance itself (press the remote-start button), "
                "then retry."
            )

    @staticmethod
    def _json_or_text(resp: Any) -> Any:
        try:
            return resp.json()
        except Exception:
            return (resp.text or "")[:300]

    @staticmethod
    def _transport_error(vendor: str, method: str, url: str, exc: Exception) -> CloudAPIError:
        return CloudAPIError(f"{vendor} {method} {url} failed: {exc}")
