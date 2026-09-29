"""Adapter registry + device-kind inference.

Adapters that can *control* a device are tried first. Hosts no adapter claims
still become passive Devices (``controllable=False``) so the app can show the
full network with a best-effort kind label.
"""
from __future__ import annotations

from ..models import Device, DiscoveredHost
from .base import DeviceAdapter
from . import demo
from .camera import CameraAdapter
from .cloud_base import CloudAdapter
from .lg_thinq import LGThinQAdapter
from .roborock import RoborockAdapter
from .samsung_tv import SamsungTVAdapter
from .smartthings import SmartThingsAdapter

# LAN adapters claim discovered hosts. Order matters: first matching adapter wins.
LAN_ADAPTERS: list[DeviceAdapter] = [
    SamsungTVAdapter(),
]

# Cloud adapters enumerate a vendor account. Each is enabled only when its
# credentials exist (SMARTTHINGS_TOKEN, LG_THINQ_TOKEN env vars; Roborock: a
# linked account via POST /integrations/roborock/login); otherwise skipped.
CLOUD_ADAPTERS: list = [
    SmartThingsAdapter(),
    LGThinQAdapter(),
    RoborockAdapter(),
]

# Dev-only sample devices (HOMEHUB_FAKE_DEVICES=1). Registered only when the env
# var is set at startup, so production /integrations output is unchanged.
if demo.enabled_by_env():
    CLOUD_ADAPTERS.append(demo.DemoAdapter())

# Cameras are configured explicitly (they need a password), so this adapter is
# not a LAN claimer; the manager lists its stored cameras alongside cloud devices.
CAMERA_ADAPTER = CameraAdapter()
CLOUD_ADAPTERS.append(CAMERA_ADAPTER)

ADAPTERS: list[DeviceAdapter] = [*LAN_ADAPTERS, *CLOUD_ADAPTERS]

_BY_ID = {a.id: a for a in ADAPTERS}


def get_adapter(adapter_id: str) -> DeviceAdapter | None:
    return _BY_ID.get(adapter_id)


def cloud_adapters(enabled_only: bool = True) -> list:
    return [a for a in CLOUD_ADAPTERS if a.enabled() or not enabled_only]


def integrations_status() -> dict[str, dict[str, object]]:
    return {
        a.id: {"name": a.name, "type": "cloud" if getattr(a, "is_cloud", False) else "lan",
               "enabled": a.enabled() if hasattr(a, "enabled") else True}
        for a in ADAPTERS
        if not getattr(a, "hidden", False)      # cameras have their own /cameras API
    }


def infer_kind(host: DiscoveredHost) -> str:
    vendor = (host.vendor or "").lower()
    services = " ".join(host.mdns_services).lower()
    st = " ".join(host.ssdp_st).lower()
    if "randomized" in vendor:
        return "phone/private"
    if "onvif" in host.sources:              # answered WS-Discovery as a NetworkVideoTransmitter
        return "camera"
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
    if 554 in host.open_ports or "_rtsp" in services:   # weak hint: only after every vendor rule
        return "camera"
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
        meta={"sources": host.sources, "openPorts": host.open_ports,
              **({"onvifUrl": host.extra["onvif"].get("onvifUrl")} if host.extra.get("onvif") else {})},
    )


def build_devices(hosts: list[DiscoveredHost]) -> list[Device]:
    devices: list[Device] = []
    for host in hosts:
        claimed = False
        for adapter in LAN_ADAPTERS:
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
