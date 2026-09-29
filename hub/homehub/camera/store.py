"""Persistent camera list, kept like other secrets: one 0600 JSON file.

Holds the camera password, so it lives in ``secret_store`` (hub/data/tokens/,
git-ignored, mode 0600) and is never included in a Device, an API answer or a log.
"""
from __future__ import annotations

import threading
import uuid
from typing import Any

from .. import secret_store

NAME = "cameras"
_lock = threading.RLock()

SECRET_FIELDS = ("password",)


def _load() -> dict[str, dict[str, Any]]:
    data = secret_store.load(NAME) or {}
    cams = data.get("cameras")
    return dict(cams) if isinstance(cams, dict) else {}


def list_cameras() -> list[dict[str, Any]]:
    with _lock:
        return [dict(c) for c in _load().values()]


def get(cam_id: str) -> dict[str, Any] | None:
    with _lock:
        c = _load().get(cam_id)
        return dict(c) if c else None


def new_id() -> str:
    return "camera:" + uuid.uuid4().hex[:8]


def put(cfg: dict[str, Any]) -> dict[str, Any]:
    with _lock:
        cams = _load()
        cams[cfg["id"]] = cfg
        secret_store.save(NAME, {"cameras": cams})
        return dict(cfg)


def remove(cam_id: str) -> bool:
    with _lock:
        cams = _load()
        if cam_id not in cams:
            return False
        del cams[cam_id]
        secret_store.save(NAME, {"cameras": cams})
        return True


def redacted(cfg: dict[str, Any]) -> dict[str, Any]:
    """Config safe to return from the API (password replaced by a flag)."""
    out = {k: v for k, v in cfg.items() if k not in SECRET_FIELDS}
    out["hasPassword"] = bool(cfg.get("password"))
    return out
