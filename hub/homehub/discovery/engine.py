"""Discovery engine: fuse ARP sweep + mDNS + SSDP + OUI into DiscoveredHosts.

Multi-modal on purpose — each source sees devices the others miss:
  * ARP sweep  -> everything with an IP (incl. silent IoT), gives MAC/vendor
  * mDNS       -> Apple/Cast/Samsung/HomeKit service hints, friendly names
  * SSDP/UPnP  -> DLNA/media renderers, friendlyName/manufacturer
"""
from __future__ import annotations

import concurrent.futures
import socket

from ..models import DiscoveredHost
from ..netutil import arp_table, ping_sweep, subnet_prefix
from . import mdns, oui, ssdp

# Control ports worth probing so adapters can fingerprint by open port.
PROBE_PORTS = [80, 443, 8001, 8002, 9197, 8080, 8443, 7676, 55000, 1400]


def _tcp_open(ip: str, port: int, timeout: float = 0.6) -> bool:
    try:
        with socket.create_connection((ip, port), timeout=timeout):
            return True
    except Exception:
        return False


def _probe_ports(ip: str) -> list[int]:
    open_ports: list[int] = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=len(PROBE_PORTS)) as ex:
        futs = {ex.submit(_tcp_open, ip, p): p for p in PROBE_PORTS}
        for fut in concurrent.futures.as_completed(futs):
            if fut.result():
                open_ports.append(futs[fut])
    return sorted(open_ports)


def scan(
    do_ports: bool = True,
    mdns_time: float = 4.0,
    ssdp_time: float = 3.0,
    online_oui: bool = True,
) -> list[DiscoveredHost]:
    prefix = subnet_prefix()

    # 1. ARP sweep (ping first to populate the cache).
    ping_sweep(prefix)
    arp = arp_table(prefix)              # {ip: mac}

    # 2 & 3. mDNS + SSDP in parallel with each other.
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as ex:
        f_mdns = ex.submit(mdns.browse, mdns_time)
        f_ssdp = ex.submit(ssdp.discover, ssdp_time)
        mdns_res = f_mdns.result()
        ssdp_res = f_ssdp.result()

    # Merge by IP, restricted to the real LAN subnet (drop loopback/link-local
    # and any stray addresses mDNS reports for the host itself).
    ips = set(arp) | set(mdns_res) | set(ssdp_res)

    def _on_lan(ip: str) -> bool:
        if ip.startswith(("127.", "169.254.")):
            return False
        last = ip.rsplit(".", 1)[-1]
        if last in ("0", "255"):          # network / broadcast addresses
            return False
        return ip.startswith(prefix + ".") if prefix else True

    hosts: dict[str, DiscoveredHost] = {}
    for ip in ips:
        if not _on_lan(ip):
            continue
        h = DiscoveredHost(ip=ip)
        if ip in arp:
            h.mac = arp[ip]
            h.vendor = oui.lookup(h.mac, online=online_oui)
            h.sources.append("arp")
        if ip in mdns_res:
            h.mdns_services = mdns_res[ip]["services"]
            names = mdns_res[ip]["names"]
            if names and not h.hostname:
                h.hostname = names[0]
            h.sources.append("mdns")
        if ip in ssdp_res:
            h.ssdp_st = ssdp_res[ip]["st"]
            info = ssdp_res[ip]["info"]
            if info.get("friendlyName") and not h.hostname:
                h.hostname = info["friendlyName"]
            if info.get("manufacturer") and not h.vendor:
                h.vendor = info["manufacturer"]
            h.extra["ssdp_info"] = info
            h.sources.append("ssdp")
        hosts[ip] = h

    # 4. Port probe (parallel across hosts) to aid adapter fingerprinting.
    if do_ports:
        with concurrent.futures.ThreadPoolExecutor(max_workers=16) as ex:
            futs = {ex.submit(_probe_ports, ip): ip for ip in hosts}
            for fut in concurrent.futures.as_completed(futs):
                hosts[futs[fut]].open_ports = fut.result()

    return sorted(hosts.values(), key=lambda h: tuple(int(o) for o in h.ip.split(".")))
