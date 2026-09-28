"""Hub configuration and on-disk locations."""
from __future__ import annotations

import os
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent.parent          # hub/
DATA_DIR = Path(os.environ.get("HOMEHUB_DATA", BASE_DIR / "data"))
TOKEN_DIR = DATA_DIR / "tokens"
DEVICES_FILE = DATA_DIR / "devices.json"
OUI_CACHE_FILE = DATA_DIR / "oui_cache.json"

HUB_NAME = os.environ.get("HOMEHUB_NAME", "HomeHub")
HTTP_HOST = os.environ.get("HOMEHUB_HTTP_HOST", "0.0.0.0")
HTTP_PORT = int(os.environ.get("HOMEHUB_HTTP_PORT", "8099"))

# Simple shared-secret auth so a random LAN device can't command the hub.
# (MVP-level; replaced by proper per-user auth when the cloud relay lands.)
API_TOKEN = os.environ.get("HOMEHUB_TOKEN", "")   # empty = auth disabled (dev)


def ensure_dirs() -> None:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    TOKEN_DIR.mkdir(parents=True, exist_ok=True)

# Browser origins allowed to call the API (CORS), comma-separated, e.g.
# "http://localhost:8080" for the Flutter web build during development.
# Empty (default) = no CORS headers: native apps don't need them, and leaving
# CORS closed stops arbitrary websites from driving the hub via the browser.
CORS_ORIGINS = [o.strip() for o in os.environ.get("HOMEHUB_CORS_ORIGINS", "").split(",") if o.strip()]
