"""HomeHub local gateway HTTP + WebSocket API.

The Flutter app is a thin client over this:
  GET  /health
  GET  /capabilities          canonical model + SmartThings/Matter matrix
  GET  /integrations          LAN/cloud adapters + enabled flag + last cloud errors
  POST /scan?lan=&cloud=      run LAN discovery and/or sync enabled cloud accounts
  GET  /devices               list devices (controllable + passive)
  GET  /devices/{id}
  POST /devices/{id}/refresh
  POST /devices/{id}/commands {capability, action, params}
  WS   /ws                    live device/event push

The hub advertises itself via Bonjour (_homehub._tcp) so the app auto-discovers
it on the LAN.
"""
from __future__ import annotations

import asyncio
import contextlib
import socket
from typing import Any

from fastapi import (
    Depends,
    FastAPI,
    Header,
    HTTPException,
    WebSocket,
    WebSocketDisconnect,
)
from pydantic import BaseModel

from . import capabilities as cap
from . import config, mappings
from .adapters import registry
from .cloud.errors import CloudNotConfiguredError
from .manager import DeviceManager
from .netutil import lan_ip

manager = DeviceManager()


# --- auth ---------------------------------------------------------------------
def require_token(x_homehub_token: str | None = Header(default=None)) -> None:
    if config.API_TOKEN and x_homehub_token != config.API_TOKEN:
        raise HTTPException(status_code=401, detail="invalid or missing hub token")


# --- websocket hub ------------------------------------------------------------
class WSHub:
    def __init__(self) -> None:
        self._clients: set[WebSocket] = set()

    async def connect(self, ws: WebSocket) -> None:
        await ws.accept()
        self._clients.add(ws)

    def disconnect(self, ws: WebSocket) -> None:
        self._clients.discard(ws)

    async def broadcast(self, event: dict[str, Any]) -> None:
        dead = []
        for ws in list(self._clients):
            try:
                await ws.send_json(event)
            except Exception:
                dead.append(ws)
        for ws in dead:
            self.disconnect(ws)


ws_hub = WSHub()


# --- bonjour advertisement ----------------------------------------------------
def _register_bonjour():
    try:
        from zeroconf import ServiceInfo, Zeroconf

        ip = lan_ip()
        if not ip:
            return None, None
        zc = Zeroconf()
        info = ServiceInfo(
            "_homehub._tcp.local.",
            f"{config.HUB_NAME}._homehub._tcp.local.",
            addresses=[socket.inet_aton(ip)],
            port=config.HTTP_PORT,
            properties={"api": "/", "ver": "0.1"},
            server=f"{config.HUB_NAME}.local.",
        )
        zc.register_service(info)
        return zc, info
    except Exception:
        return None, None


@contextlib.asynccontextmanager
async def lifespan(app: FastAPI):
    config.ensure_dirs()
    zc, info = _register_bonjour()
    try:
        yield
    finally:
        if zc and info:
            with contextlib.suppress(Exception):
                zc.unregister_service(info)
                zc.close()


app = FastAPI(title="HomeHub Gateway", version="0.1.0", lifespan=lifespan)


# --- request models -----------------------------------------------------------
class CommandBody(BaseModel):
    capability: str
    action: str
    params: dict[str, Any] = {}


# --- routes -------------------------------------------------------------------
@app.get("/health")
def health() -> dict[str, Any]:
    return {
        "ok": True,
        "name": config.HUB_NAME,
        "ip": lan_ip(),
        "scanning": manager.scanning,
        "deviceCount": len(manager.list_devices()),
        "integrations": {k: v["enabled"] for k, v in registry.integrations_status().items()},
    }


@app.get("/integrations")
def integrations() -> dict[str, Any]:
    return {"integrations": registry.integrations_status(), "cloudErrors": manager.cloud_errors}


@app.get("/capabilities")
def capabilities() -> dict[str, Any]:
    return {
        "canonical": {
            k: {
                "actions": spec.actions,
                "state": spec.state,
                "uiHint": spec.ui_hint,
            }
            for k, spec in cap.CANONICAL.items()
        },
        "standardsMatrix": mappings.full_matrix(),
    }


@app.get("/devices")
def list_devices() -> dict[str, Any]:
    return {"devices": [d.to_dict() for d in manager.list_devices()]}


@app.get("/devices/{device_id:path}")
def get_device(device_id: str) -> dict[str, Any]:
    dev = manager.get(device_id)
    if dev is None:
        raise HTTPException(404, "device not found")
    return dev.to_dict()


@app.post("/scan", dependencies=[Depends(require_token)])
async def scan(lan: bool = True, cloud: bool = True) -> dict[str, Any]:
    devices = await asyncio.to_thread(manager.scan, lan=lan, cloud=cloud)
    payload = {"devices": [d.to_dict() for d in devices], "cloudErrors": manager.cloud_errors}
    await ws_hub.broadcast({"type": "devices", **payload})
    return payload


@app.post("/devices/{device_id:path}/refresh", dependencies=[Depends(require_token)])
async def refresh(device_id: str) -> dict[str, Any]:
    dev = await asyncio.to_thread(manager.refresh, device_id)
    if dev is None:
        raise HTTPException(404, "device not found")
    return dev.to_dict()


@app.post("/devices/{device_id:path}/commands", dependencies=[Depends(require_token)])
async def command(device_id: str, body: CommandBody) -> dict[str, Any]:
    try:
        result = await asyncio.to_thread(
            manager.execute, device_id, body.capability, body.action, body.params
        )
    except KeyError as e:
        raise HTTPException(404, str(e)) from e
    except CloudNotConfiguredError as e:
        raise HTTPException(503, str(e)) from e
    except PermissionError as e:
        raise HTTPException(403, str(e)) from e
    except ValueError as e:
        raise HTTPException(400, str(e)) from e
    except Exception as e:  # noqa: BLE001
        raise HTTPException(502, str(e)) from e
    await ws_hub.broadcast(
        {"type": "command", "deviceId": device_id,
         "capability": body.capability, "action": body.action, "result": result}
    )
    return {"ok": True, "result": result}


@app.websocket("/ws")
async def ws_endpoint(ws: WebSocket) -> None:
    await ws_hub.connect(ws)
    try:
        await ws.send_json(
            {"type": "devices", "devices": [d.to_dict() for d in manager.list_devices()]}
        )
        while True:
            await ws.receive_text()   # keepalive; client may ping
    except WebSocketDisconnect:
        ws_hub.disconnect(ws)
    except Exception:
        ws_hub.disconnect(ws)
