"""Link cloud devices to the same physical device found on the LAN.

Brand-agnostic: uses only canonical Device fields plus the hints cloud
adapters publish in ``Device.meta["match"]`` ({brand, model, name, mac}).

Rules
  * A cloud device links to a LAN device when the MAC matches, or when kind +
    brand agree and the (normalized) name matches or one model number is a
    prefix of the other. Ambiguous matches (>1 candidate) are NOT linked.
  * LAN device controllable (e.g. samsung_local)  -> LAN stays primary; the
    cloud device is attached as ``meta["fallback"]``; cloud-only capabilities /
    actions are added; empty LAN state is filled from cloud state. The
    manager routes to the LAN adapter first and falls back to cloud.
  * LAN device passive (no adapter)               -> the cloud device replaces
    it, inheriting ip/mac so the app still sees one entry.
"""
from __future__ import annotations

import copy
import re

from .models import Device


def _norm(s: str | None) -> str:
    s = (s or "").lower()
    s = re.sub(r"^\[[^\]]*\]\s*", "", s)          # "[TV] Samsung ..." -> "samsung ..."
    return re.sub(r"[^a-z0-9]", "", s)


def _mac(s: str | None) -> str:
    return re.sub(r"[^0-9a-f]", "", (s or "").lower())


def _model_match(a: str | None, b: str | None) -> bool:
    a, b = _norm(a), _norm(b)
    if len(a) < 6 or len(b) < 6:
        return False
    return a.startswith(b) or b.startswith(a)


def _brand_ok(lan: Device, brand: str | None) -> bool:
    if not brand:
        return True
    first = _norm(brand.split()[0]) if brand.split() else ""
    return not lan.vendor or first in _norm(lan.vendor)


def same_device(lan: Device, cloud: Device) -> bool:
    hint = cloud.meta.get("match") or {}
    cmac = _mac(hint.get("mac") or cloud.mac)
    if cmac and cmac == _mac(lan.mac):
        return True
    if not lan.controllable:
        # Passive LAN kinds come from OUI guesses (every Samsung MAC looks like
        # a "tv"), so only link on an exact name match.
        return bool(_norm(lan.name)) and _norm(lan.name) == _norm(hint.get("name") or cloud.name)
    if lan.kind != cloud.kind or not _brand_ok(lan, hint.get("brand")):
        return False
    name_ok = bool(_norm(lan.name)) and _norm(lan.name) == _norm(hint.get("name") or cloud.name)
    return name_ok or _model_match(lan.meta.get("model"), hint.get("model"))


def _attach(primary: Device, cloud: Device) -> Device:
    merged = copy.deepcopy(primary)
    merged.meta["primaryCapabilities"] = {k: list(v.actions) for k, v in primary.capabilities.items()}
    merged.meta["fallback"] = {"adapter": cloud.adapter, "id": cloud.id, "device": cloud.to_dict()}
    merged.meta["linkedIds"] = [cloud.id]
    for key, cinst in cloud.capabilities.items():
        if key not in merged.capabilities:
            merged.capabilities[key] = copy.deepcopy(cinst)
            continue
        linst = merged.capabilities[key]
        linst.actions += [a for a in cinst.actions if a not in linst.actions]
        for sk, sv in cinst.state.items():
            if linst.state.get(sk) in (None, "unknown", [], {}) and sv is not None:
                linst.state[sk] = sv
    return merged


def merge(lan: list[Device], cloud: list[Device]) -> tuple[list[Device], dict[str, str]]:
    """Return (merged device list, alias map old_id -> surviving id)."""
    out: dict[str, Device] = {d.id: d for d in lan}
    aliases: dict[str, str] = {}
    linked: set[str] = set()
    for c in cloud:
        cands = [d for d in lan if d.id not in linked and same_device(d, c)]
        if len(cands) != 1:
            out[c.id] = c
            if len(cands) > 1:
                c.meta["linkAmbiguous"] = [d.id for d in cands]
            continue
        l = cands[0]
        linked.add(l.id)
        if l.controllable:
            out[l.id] = _attach(l, c)
            aliases[c.id] = l.id
        else:
            m = copy.deepcopy(c)
            m.ip, m.mac, m.reachable = l.ip, l.mac or m.mac, True
            m.meta["lanHostId"] = l.id
            del out[l.id]
            out[m.id] = m
            aliases[l.id] = m.id
    return list(out.values()), aliases
