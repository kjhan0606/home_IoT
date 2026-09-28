"""Tiny JSON persistence for the last device snapshot.

Lets the API serve devices immediately on startup (and control them) without
forcing a fresh network scan every time. Per-device secrets (Samsung tokens)
live in their own files, not here.

Layout: {"devices": [merged view], "lan": [...], "cloud": [...]}. The raw
LAN/cloud lists let the manager re-merge after a LAN-only or cloud-only sync.
"""
from __future__ import annotations

import json
from typing import Any

from . import config
from .models import Device


def save_devices(devices: list[Device], lan: list[Device] | None = None,
                 cloud: list[Device] | None = None) -> None:
    config.ensure_dirs()
    payload: dict[str, Any] = {"devices": [d.to_dict() for d in devices]}
    if lan is not None:
        payload["lan"] = [d.to_dict() for d in lan]
    if cloud is not None:
        payload["cloud"] = [d.to_dict() for d in cloud]
    config.DEVICES_FILE.write_text(json.dumps(payload, indent=2, ensure_ascii=False))


def _load() -> dict[str, Any]:
    try:
        return json.loads(config.DEVICES_FILE.read_text())
    except Exception:
        return {}


def load_devices() -> list[Device]:
    return [Device.from_dict(d) for d in _load().get("devices", [])]


def load_sources() -> tuple[list[Device] | None, list[Device] | None]:
    p = _load()
    lan = [Device.from_dict(d) for d in p["lan"]] if "lan" in p else None
    cloud = [Device.from_dict(d) for d in p["cloud"]] if "cloud" in p else None
    return lan, cloud
