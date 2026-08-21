"""Tiny JSON persistence for the last device snapshot.

Lets the API serve devices immediately on startup (and control them) without
forcing a fresh network scan every time. Per-device secrets (Samsung tokens)
live in their own files, not here.
"""
from __future__ import annotations

import json

from . import config
from .models import Device


def save_devices(devices: list[Device]) -> None:
    config.ensure_dirs()
    payload = {"devices": [d.to_dict() for d in devices]}
    config.DEVICES_FILE.write_text(json.dumps(payload, indent=2, ensure_ascii=False))


def load_devices() -> list[Device]:
    try:
        payload = json.loads(config.DEVICES_FILE.read_text())
    except Exception:
        return []
    return [Device.from_dict(d) for d in payload.get("devices", [])]
