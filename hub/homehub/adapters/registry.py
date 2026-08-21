"""Adapter registry + device-kind inference.

Adapters that can *control* a device are tried first. Hosts no adapter claims
still become passive Devices (``controllable=False``) so the app can show the
full network with a best-effort kind label.
"""
from __future__ import annotations

from ..models import Device, DiscoveredHost
from .base import DeviceAdapter
from .samsung_tv import SamsungTVAdapter

# Order matters: first matching adapter wins.
ADAPTERS: list[DeviceAdapter] = [
    SamsungTVAdapter(),
]

_BY_ID = {a.id: a for a in ADAPTERS}


def get_adapter(adapter_id: str) -> DeviceAdapter | None:
    return _BY_ID.get(adapter_id)


def infer_kind(host: DiscoveredHost) -> str:
    vendor = (host.vendor or "").lower()
    services = " ".join(host.mdns_services).lower()
    st = " ".join(host.ssdp_st).lower()
    if "randomized" in vendor:
        return "phone/private"
    if "router" in vendor or "mercury" in vendor:
        return "router"
    if "roborock" in vendor or "_miio" in services:
        return "vacuum"
    if "samsung" in vendor or "samsungmsf" in services:
        return "tv"
    if "marusys" in vendor or "stb" in vendor:
        return "set-top-box"
    if "_googlecast" in services:
        return "cast"
    if "_airplay" in services or "_raop" in services:
        return "airplay"
    if "_printer" in services or "_ipp" in services:
        return "printer"
    if "mediarenderer" in st or "dial" in services:
        return "media"
    return "unknown"


def build_passive_device(host: DiscoveredHost) -> Device:
    name = host.hostname or host.vendor or host.ip
    return Device(
        id=f"host:{host.mac or host.ip}",
        name=name,
        adapter="unknown",
        kind=infer_kind(host),
        ip=host.ip,
        mac=host.mac,
        vendor=host.vendor,
        reachable=True,
        controllable=False,
        capabilities={},
        meta={"sources": host.sources, "openPorts": host.open_ports},
    )


def build_devices(hosts: list[DiscoveredHost]) -> list[Device]:
    devices: list[Device] = []
    for host in hosts:
        claimed = False
        for adapter in ADAPTERS:
            try:
                if adapter.matches(host):
                    devices.append(adapter.build_device(host))
                    claimed = True
                    break
            except Exception:
                continue
        if not claimed:
            devices.append(build_passive_device(host))
    return devices
