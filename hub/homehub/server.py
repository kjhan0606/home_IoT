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
  GET  /devices/{id}/map      vacuum map metadata (+ base64 PNG); /map.png = image
  GET  /integrations/roborock  link status;  POST .../request-code, .../login, .../unlink
  GET  /devices/{id}/snapshot.jpg   camera: one JPEG           (token required)
  GET  /devices/{id}/stream.mjpeg   camera: MJPEG relay          (token required)
  GET  /devices/{id}/stream         camera: stream info (RTSP URI without password)
  GET  /cameras/discover            ONVIF WS-Discovery on the LAN
  GET  /cameras                     configured cameras (password never returned)
  POST /cameras                     add {protocol: onvif|rtsp|http, ...};  DELETE /cameras/{id}
  WS   /ws                    live device/event push

The hub advertises itself via Bonjour (_homehub._tcp) so the app auto-discovers
it on the LAN.
"""
from __future__ import annotations

import asyncio
import contextlib
import socket
from typing import Any

import base64

from fastapi.responses import StreamingResponse
from fastapi import (
    Depends,
    FastAPI,
    Header,
    HTTPException,
    Request,
    Response,
    WebSocket,
    WebSocketDisconnect,
)
from pydantic import BaseModel

from . import capabilities as cap
from . import config, mappings
from .adapters import registry
from .camera import media as cam_media
from .camera import onvif as cam_onvif
from .camera import store as cam_store
from .cloud.errors import CloudAPIError, CloudNotConfiguredError
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
    if registry.get_adapter("demo") is not None:     # HOMEHUB_FAKE_DEVICES=1: show samples at once
        with contextlib.suppress(Exception):
            await asyncio.to_thread(manager.scan, lan=False, cloud=True)
    if cam_store.list_cameras():                     # refresh configured cameras' online state
        with contextlib.suppress(Exception):
            await asyncio.to_thread(manager.sync_adapter, "camera")
    zc, info = _register_bonjour()
    try:
        yield
    finally:
        if zc and info:
            with contextlib.suppress(Exception):
                zc.unregister_service(info)
                zc.close()
        for a in registry.CLOUD_ADAPTERS:
            if hasattr(a, "close"):
                with contextlib.suppress(Exception):
                    a.close()


app = FastAPI(title="HomeHub Gateway", version="0.1.0", lifespan=lifespan)
if config.CORS_ORIGINS:
    from fastapi.middleware.cors import CORSMiddleware

    app.add_middleware(
        CORSMiddleware, allow_origins=config.CORS_ORIGINS, allow_methods=["*"], allow_headers=["*"],
    )


# --- request models -----------------------------------------------------------
class RoborockCodeBody(BaseModel):
    email: str


class RoborockLoginBody(BaseModel):
    email: str
    code: str | None = None
    password: str | None = None


class CameraBody(BaseModel):
    protocol: str                       # onvif | rtsp | http
    name: str = ""
    address: str | None = None          # onvif: 192.168.0.50 or http://host:port/onvif/device_service
    url: str | None = None              # rtsp / http: full URL (credentials may be embedded or separate)
    username: str = ""
    password: str = ""
    room: str | None = None
    verify: bool = True


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


# --- Roborock account link (secrets never returned) ---------------------------
def _roborock():
    a = registry.get_adapter("roborock")
    if a is None:
        raise HTTPException(404, "roborock adapter not loaded")
    return a


def _link_call(fn, *args, **kwargs) -> dict[str, Any]:
    try:
        return fn(*args, **kwargs)
    except ValueError as e:
        raise HTTPException(400, str(e)) from None
    except CloudAPIError as e:
        raise HTTPException(429 if e.status == 429 else 502, str(e)) from None


@app.get("/integrations/roborock", dependencies=[Depends(require_token)])
def roborock_status() -> dict[str, Any]:
    return _roborock().link_status()


@app.post("/integrations/roborock/request-code", dependencies=[Depends(require_token)])
async def roborock_request_code(body: RoborockCodeBody) -> dict[str, Any]:
    return await asyncio.to_thread(_link_call, _roborock().request_code, body.email)


@app.post("/integrations/roborock/login", dependencies=[Depends(require_token)])
async def roborock_login(body: RoborockLoginBody) -> dict[str, Any]:
    return await asyncio.to_thread(
        _link_call, _roborock().login, body.email, code=body.code, password=body.password)


@app.post("/integrations/roborock/unlink", dependencies=[Depends(require_token)])
async def roborock_unlink() -> dict[str, Any]:
    res = await asyncio.to_thread(_roborock().unlink)
    await asyncio.to_thread(manager.scan, lan=False, cloud=True)   # drop its devices
    return res


# --- cameras (declared before the greedy /devices/{id:path} route) ------------
def _camera():
    a = registry.get_adapter("camera")
    if a is None:
        raise HTTPException(404, "camera adapter not loaded")
    return a


def _camera_errors(fn, *args):
    try:
        return fn(*args)
    except KeyError as e:
        raise HTTPException(404, str(e)) from e
    except LookupError as e:
        raise HTTPException(404, str(e)) from e
    except cam_onvif.OnvifAuthError as e:
        raise HTTPException(403, str(e)) from e           # not 401: that means "wrong hub token"
    except cam_media.MediaError as e:
        raise HTTPException(403 if "user name or password" in str(e) else 502, str(e)) from e
    except cam_onvif.OnvifError as e:
        raise HTTPException(502, str(e)) from e
    except ValueError as e:
        raise HTTPException(400, str(e)) from e


_MAX_STREAMS = 4
_streams_open = 0


@app.get("/cameras/discover", dependencies=[Depends(require_token)])
async def cameras_discover() -> dict[str, Any]:
    """ONVIF cameras answering WS-Discovery (not yet necessarily added)."""
    found = await asyncio.to_thread(cam_onvif.ws_discover, 3.0, lan_ip())
    added = {c.get("host") for c in cam_store.list_cameras()}
    return {"cameras": [{**f, "added": f["host"] in added} for f in found]}


@app.get("/cameras", dependencies=[Depends(require_token)])
def cameras_list() -> dict[str, Any]:
    return {"cameras": [cam_store.redacted(c) for c in cam_store.list_cameras()]}


@app.post("/cameras", dependencies=[Depends(require_token)])
async def cameras_add(body: CameraBody) -> dict[str, Any]:
    dev = await asyncio.to_thread(_camera_errors, _camera().add_camera, body.model_dump())
    await asyncio.to_thread(manager.sync_adapter, "camera")
    d = manager.get(dev.id)
    payload = {"device": (d or dev).to_dict()}
    await ws_hub.broadcast({"type": "devices", "devices": [x.to_dict() for x in manager.list_devices()]})
    return payload


@app.delete("/cameras/{camera_id:path}", dependencies=[Depends(require_token)])
async def cameras_remove(camera_id: str) -> dict[str, Any]:
    if not _camera().remove_camera(camera_id):
        raise HTTPException(404, "camera not found")
    await asyncio.to_thread(manager.sync_adapter, "camera")
    await ws_hub.broadcast({"type": "devices", "devices": [x.to_dict() for x in manager.list_devices()]})
    return {"ok": True}


@app.get("/devices/{device_id:path}/snapshot.jpg", dependencies=[Depends(require_token)])
async def camera_snapshot(device_id: str) -> Response:
    jpeg = await asyncio.to_thread(_camera_errors, manager.camera_snapshot, device_id)
    return Response(content=jpeg, media_type="image/jpeg", headers={"Cache-Control": "no-store"})


@app.get("/devices/{device_id:path}/stream.mjpeg", dependencies=[Depends(require_token)])
async def camera_mjpeg(device_id: str, request: Request, fps: int = 5) -> StreamingResponse:
    """MJPEG relay (multipart/x-mixed-replace). RTSP cameras need ffmpeg on the hub."""
    global _streams_open
    if _streams_open >= _MAX_STREAMS:
        raise HTTPException(429, "too many open camera streams")
    frames = await asyncio.to_thread(_camera_errors, manager.camera_frames, device_id, max(1, min(fps, 15)))
    it = iter(frames)
    _streams_open += 1

    async def body():
        global _streams_open
        try:
            while not await request.is_disconnected():
                jpeg = await asyncio.to_thread(next, it, None)
                if jpeg is None:
                    break
                yield cam_media.multipart_frame(jpeg)
        except Exception:  # noqa: BLE001 - camera dropped: just end the stream
            pass
        finally:
            _streams_open -= 1
            with contextlib.suppress(Exception):
                await asyncio.to_thread(frames.close)

    return StreamingResponse(body(), media_type=cam_media.MJPEG_MEDIA_TYPE,
                             headers={"Cache-Control": "no-store"})


@app.get("/devices/{device_id:path}/stream", dependencies=[Depends(require_token)])
async def camera_stream_info(device_id: str) -> dict[str, Any]:
    return await asyncio.to_thread(_camera_errors, manager.camera_stream_info, device_id)


# --- vacuum map (declared before the greedy /devices/{id:path} route) --------
def _map_or_http(device_id: str) -> tuple[bytes | None, dict[str, Any]]:
    try:
        return manager.get_map(device_id)
    except KeyError as e:
        raise HTTPException(404, str(e)) from e
    except LookupError as e:
        raise HTTPException(404, str(e)) from e
    except CloudNotConfiguredError as e:
        raise HTTPException(503, str(e)) from e
    except ValueError as e:
        raise HTTPException(400, str(e)) from e
    except Exception as e:  # noqa: BLE001
        raise HTTPException(502, str(e)) from e


@app.get("/devices/{device_id:path}/map.png")
async def device_map_png(device_id: str, cached: bool = True) -> Response:
    hit = manager.cached_map(device_id) if cached else None
    png, _ = hit if hit else await asyncio.to_thread(_map_or_http, device_id)
    if not png:
        raise HTTPException(404, "no map image")
    return Response(content=png, media_type="image/png")


@app.get("/devices/{device_id:path}/map")
async def device_map(device_id: str, image: bool = True) -> dict[str, Any]:
    png, meta = await asyncio.to_thread(_map_or_http, device_id)
    out = {"deviceId": device_id, **meta, "imageUrl": f"/devices/{device_id}/map.png"}
    if image and png:
        out["image"] = {**meta["image"], "pngBase64": base64.b64encode(png).decode()}
    return out


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
    dev = manager.get(device_id)
    await ws_hub.broadcast(
        {"type": "command", "deviceId": device_id,
         "capability": body.capability, "action": body.action, "result": result,
         "device": dev.to_dict() if dev else None}
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
