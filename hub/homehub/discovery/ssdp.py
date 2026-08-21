"""SSDP / UPnP discovery via an M-SEARCH multicast.

Returns per-IP the advertised search-targets (ST) and, when cheaply available,
the friendlyName/manufacturer from the device description XML.
"""
from __future__ import annotations

import re
import socket
from collections import defaultdict

import requests

_MCAST = ("239.255.255.250", 1900)
_MSEARCH = (
    "M-SEARCH * HTTP/1.1\r\n"
    "HOST: 239.255.255.250:1900\r\n"
    'MAN: "ssdp:discover"\r\n'
    "MX: 2\r\n"
    "ST: ssdp:all\r\n\r\n"
).encode()


def _fetch_description(location: str) -> dict[str, str]:
    try:
        r = requests.get(location, timeout=2)
        xml = r.text
        out = {}
        for tag in ("friendlyName", "manufacturer", "modelName"):
            m = re.search(rf"<{tag}>(.*?)</{tag}>", xml, re.S)
            if m:
                out[tag] = m.group(1).strip()
        return out
    except Exception:
        return {}


def discover(timeout: float = 3.0) -> dict[str, dict]:
    """M-SEARCH the LAN. Returns {ip: {"st": [...], "info": {...}}}."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 2)
    s.settimeout(timeout)
    by_ip: dict[str, dict] = defaultdict(lambda: {"st": set(), "location": None})
    try:
        s.sendto(_MSEARCH, _MCAST)
        while True:
            try:
                data, addr = s.recvfrom(65507)
            except socket.timeout:
                break
            ip = addr[0]
            text = data.decode("utf-8", "replace")
            st = re.search(r"^ST:\s*(.+)$", text, re.I | re.M)
            loc = re.search(r"^LOCATION:\s*(.+)$", text, re.I | re.M)
            if st:
                by_ip[ip]["st"].add(st.group(1).strip())
            if loc and not by_ip[ip]["location"]:
                by_ip[ip]["location"] = loc.group(1).strip()
    finally:
        s.close()

    result: dict[str, dict] = {}
    for ip, v in by_ip.items():
        info = _fetch_description(v["location"]) if v["location"] else {}
        result[ip] = {"st": sorted(v["st"]), "info": info}
    return result
