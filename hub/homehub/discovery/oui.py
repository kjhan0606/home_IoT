"""MAC OUI -> vendor lookup, with an on-disk cache and an offline seed table.

Randomized (locally-administered) MACs are reported as such instead of being
looked up, since their vendor is meaningless.
"""
from __future__ import annotations

import json
import threading

import requests

from .. import config
from ..netutil import is_locally_administered, normalize_mac

# Offline seed for prefixes we've already identified on this network, so the
# hub still labels core devices with no internet / before the API responds.
_SEED: dict[str, str] = {
    "0c:96:cd": "MERCURY (router)",
    "b0:4a:39": "Roborock",
    "f8:04:2e": "Samsung",
    "00:1d:ec": "Marusys (IPTV STB)",
}

_lock = threading.Lock()
_cache: dict[str, str] | None = None


def _load() -> dict[str, str]:
    global _cache
    if _cache is None:
        try:
            _cache = json.loads(config.OUI_CACHE_FILE.read_text())
        except Exception:
            _cache = {}
    return _cache


def _save() -> None:
    try:
        config.ensure_dirs()
        config.OUI_CACHE_FILE.write_text(json.dumps(_cache or {}, indent=2))
    except Exception:
        pass


def lookup(mac: str | None, online: bool = True) -> str | None:
    if not mac:
        return None
    mac = normalize_mac(mac)
    if is_locally_administered(mac):
        return "(randomized MAC)"
    prefix = ":".join(mac.split(":")[:3])
    if prefix in _SEED:
        return _SEED[prefix]
    with _lock:
        cache = _load()
        if prefix in cache:
            return cache[prefix]
    if not online:
        return None
    try:
        r = requests.get(f"https://api.macvendors.com/{prefix}", timeout=5)
        if r.status_code == 200 and r.text.strip():
            vendor = r.text.strip()
            with _lock:
                _load()[prefix] = vendor
                _save()
            return vendor
    except Exception:
        pass
    return None
