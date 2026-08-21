"""Core data models shared across discovery, adapters, and the API layer.

Plain dataclasses (no pydantic) so this layer stays import-light and testable;
FastAPI serializes the ``to_dict()`` output directly.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

from .capabilities import CapabilityInstance


@dataclass
class DiscoveredHost:
    """Raw result of network discovery, before an adapter claims it. One host
    may be seen by several discovery sources (ARP, mDNS, SSDP) and merged."""

    ip: str
    mac: str | None = None
    hostname: str | None = None
    vendor: str | None = None            # from MAC OUI lookup
    sources: list[str] = field(default_factory=list)   # ["arp","mdns","ssdp"]
    # protocol hints collected during discovery, consumed by adapter.matches()
    mdns_services: list[str] = field(default_factory=list)
    ssdp_st: list[str] = field(default_factory=list)
    open_ports: list[int] = field(default_factory=list)
    extra: dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        return {
            "ip": self.ip,
            "mac": self.mac,
            "hostname": self.hostname,
            "vendor": self.vendor,
            "sources": self.sources,
            "mdnsServices": self.mdns_services,
            "ssdpSt": self.ssdp_st,
            "openPorts": self.open_ports,
        }


@dataclass
class Device:
    """A device the hub can present and (if an adapter claimed it) control."""

    id: str                              # stable id (adapter-scoped)
    name: str
    adapter: str                         # adapter id that owns control, or "unknown"
    kind: str = "unknown"                # tv, vacuum, light, phone, router, ...
    ip: str | None = None
    mac: str | None = None
    vendor: str | None = None
    reachable: bool = False
    controllable: bool = False           # True once an adapter claims it
    capabilities: dict[str, CapabilityInstance] = field(default_factory=dict)
    meta: dict[str, Any] = field(default_factory=dict)   # model, fw, tokens ref...

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "name": self.name,
            "adapter": self.adapter,
            "kind": self.kind,
            "ip": self.ip,
            "mac": self.mac,
            "vendor": self.vendor,
            "reachable": self.reachable,
            "controllable": self.controllable,
            "capabilities": {k: v.to_dict() for k, v in self.capabilities.items()},
            "meta": {k: v for k, v in self.meta.items() if k != "secrets"},
        }

    @classmethod
    def from_dict(cls, d: dict[str, Any]) -> "Device":
        caps = {
            k: CapabilityInstance.from_dict(v)
            for k, v in (d.get("capabilities") or {}).items()
        }
        return cls(
            id=d["id"],
            name=d["name"],
            adapter=d.get("adapter", "unknown"),
            kind=d.get("kind", "unknown"),
            ip=d.get("ip"),
            mac=d.get("mac"),
            vendor=d.get("vendor"),
            reachable=d.get("reachable", False),
            controllable=d.get("controllable", False),
            capabilities=caps,
            meta=dict(d.get("meta", {})),
        )
