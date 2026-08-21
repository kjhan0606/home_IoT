"""mDNS / Bonjour discovery via zeroconf.

Time-boxed browse of common service types; returns per-IP service hints that
adapters use to recognize devices (e.g. an ``_airplay._tcp`` service strongly
implies an Apple TV / AirPlay-capable TV).
"""
from __future__ import annotations

import socket
import time
from collections import defaultdict

from zeroconf import ServiceBrowser, ServiceListener, Zeroconf

COMMON_TYPES = [
    "_airplay._tcp.local.",
    "_raop._tcp.local.",            # AirPlay audio
    "_googlecast._tcp.local.",      # Chromecast / Android TV
    "_spotify-connect._tcp.local.",
    "_samsungmsf._tcp.local.",      # Samsung Multiscreen (Tizen TVs)
    "_dial._tcp.local.",            # DIAL (smart TVs)
    "_http._tcp.local.",
    "_ipp._tcp.local.",             # printers
    "_printer._tcp.local.",
    "_hap._tcp.local.",             # HomeKit accessories
    "_device-info._tcp.local.",
    "_miio._udp.local.",            # Xiaomi/Roborock
]


class _Collector(ServiceListener):
    def __init__(self) -> None:
        # ip -> {"services": set, "names": set}
        self.by_ip: dict[str, dict[str, set]] = defaultdict(
            lambda: {"services": set(), "names": set()}
        )

    def _record(self, zc: Zeroconf, type_: str, name: str) -> None:
        try:
            info = zc.get_service_info(type_, name, timeout=1500)
        except Exception:
            info = None
        if not info:
            return
        addrs = []
        try:
            addrs = [socket.inet_ntoa(a) for a in info.addresses if len(a) == 4]
        except Exception:
            pass
        for ip in addrs:
            self.by_ip[ip]["services"].add(type_.replace(".local.", ""))
            self.by_ip[ip]["names"].add(name.split(".")[0])

    def add_service(self, zc: Zeroconf, type_: str, name: str) -> None:
        self._record(zc, type_, name)

    def update_service(self, zc: Zeroconf, type_: str, name: str) -> None:
        self._record(zc, type_, name)

    def remove_service(self, zc: Zeroconf, type_: str, name: str) -> None:
        pass


def browse(duration: float = 4.0) -> dict[str, dict[str, list]]:
    """Browse common mDNS services for ``duration`` seconds.

    Returns {ip: {"services": [...], "names": [...]}}.
    """
    zc = Zeroconf()
    collector = _Collector()
    browsers = [ServiceBrowser(zc, t, collector) for t in COMMON_TYPES]
    try:
        time.sleep(duration)
    finally:
        for b in browsers:
            try:
                b.cancel()
            except Exception:
                pass
        zc.close()
    return {
        ip: {"services": sorted(v["services"]), "names": sorted(v["names"])}
        for ip, v in collector.by_ip.items()
    }
