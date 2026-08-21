"""Low-level network helpers: LAN addressing, Wake-on-LAN, ARP/ping sweep.

Kept dependency-free (stdlib + a couple of macOS/Unix CLIs) so discovery works
without elevated privileges.
"""
from __future__ import annotations

import concurrent.futures
import re
import socket
import subprocess
from functools import lru_cache

_IPV4 = re.compile(r"^\d{1,3}(?:\.\d{1,3}){3}$")


@lru_cache(maxsize=1)
def default_gateway() -> str | None:
    """Return the physical default gateway IP (skips VPN utun routes)."""
    try:
        out = subprocess.run(
            ["netstat", "-rn"], capture_output=True, text=True, timeout=5
        ).stdout
    except Exception:
        return None
    for line in out.splitlines():
        parts = line.split()
        if len(parts) >= 4 and parts[0] == "default":
            gw, iface = parts[1], parts[-1]
            if _IPV4.match(gw) and not iface.startswith("utun"):
                return gw
    return None


def lan_ip() -> str | None:
    """Source IP this host uses to reach the LAN gateway (the Wi-Fi/en0 addr)."""
    gw = default_gateway()
    if not gw:
        return None
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect((gw, 9))          # gateway is on-link -> no VPN detour
        ip = s.getsockname()[0]
        s.close()
        return ip
    except OSError:
        return None


def subnet_prefix() -> str | None:
    """Assumes a /24 home network -> '192.168.45'."""
    ip = lan_ip()
    return ip.rsplit(".", 1)[0] if ip else None


def broadcast_addr() -> str | None:
    pfx = subnet_prefix()
    return f"{pfx}.255" if pfx else None


def wake_on_lan(mac: str) -> int:
    """Send WoL magic packets, bound to the LAN interface + subnet broadcast.

    Returns the number of packets sent. Works around multi-interface (VPN)
    setups where a plain 255.255.255.255 broadcast raises 'No route to host'.
    """
    mac_bytes = bytes(int(x, 16) for x in re.split(r"[:\-]", mac))
    if len(mac_bytes) != 6:
        raise ValueError(f"bad MAC: {mac!r}")
    magic = b"\xff" * 6 + mac_bytes * 16

    src = lan_ip()
    bcast = broadcast_addr()
    targets: list[tuple[str, int]] = []
    if bcast:
        targets += [(bcast, 9), (bcast, 7)]
    targets.append(("255.255.255.255", 9))

    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    if src:
        try:
            s.bind((src, 0))
        except OSError:
            pass
    sent = 0
    for ip, port in targets:
        for _ in range(3):
            try:
                s.sendto(magic, (ip, port))
                sent += 1
            except OSError:
                pass
    s.close()
    return sent


def ping(ip: str, timeout_ms: int = 300) -> bool:
    try:
        r = subprocess.run(
            ["ping", "-c", "1", "-W", str(timeout_ms), ip],
            capture_output=True, timeout=(timeout_ms / 1000) + 1.5,
        )
        return r.returncode == 0
    except Exception:
        return False


def ping_sweep(prefix: str | None = None, workers: int = 128) -> list[str]:
    """Ping every host in the /24 to populate the ARP cache; return responders."""
    prefix = prefix or subnet_prefix()
    if not prefix:
        return []
    hosts = [f"{prefix}.{i}" for i in range(1, 255)]
    alive: list[str] = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as ex:
        for ip, ok in zip(hosts, ex.map(ping, hosts)):
            if ok:
                alive.append(ip)
    return alive


def arp_table(prefix: str | None = None) -> dict[str, str]:
    """Return {ip: mac} from the system ARP cache for the local subnet."""
    prefix = prefix or subnet_prefix()
    result: dict[str, str] = {}
    try:
        out = subprocess.run(
            ["arp", "-a", "-n"], capture_output=True, text=True, timeout=5
        ).stdout
    except Exception:
        return result
    for line in out.splitlines():
        m = re.search(r"\((\d+\.\d+\.\d+\.\d+)\) at ([0-9a-fA-F:]+)", line)
        if not m:
            continue
        ip, mac = m.group(1), m.group(2)
        if "incomplete" in line.lower():
            continue
        if prefix and not ip.startswith(prefix + "."):
            continue
        result[ip] = normalize_mac(mac)
    return result


def normalize_mac(mac: str) -> str:
    """Zero-pad each octet and lowercase: 'f8:4:2e' -> 'f8:04:2e'."""
    parts = re.split(r"[:\-]", mac)
    return ":".join(p.zfill(2).lower() for p in parts)


def is_locally_administered(mac: str) -> bool:
    """True for randomized/private MACs (2nd-least-significant bit of 1st octet)."""
    try:
        first = int(mac.split(":")[0], 16)
        return bool(first & 0b10)
    except Exception:
        return False
