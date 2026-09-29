"""IP camera / CCTV adapter (brand-neutral).

One adapter for every camera family, chosen per camera by how it was added:

  * ``onvif`` - ONVIF Profile S/T (WS-Security digest): profiles, RTSP stream URI,
    snapshot URI and PTZ are read from the camera itself.
  * ``rtsp``  - a manually entered ``rtsp://`` URL (no ONVIF needed).
  * ``http``  - a manually entered ``http(s)://`` URL that is either an MJPEG
    stream (``multipart/x-mixed-replace``) or a single-JPEG snapshot URL.
  * ``demo``  - never created here (see ``demo.py``); the demo adapter reuses the
    same capability shape.

Cameras are *configured*, not claimed from LAN scans (a scan cannot know the
password), so this adapter enumerates the hub's camera list like a cloud adapter
does. Credentials are stored in ``camera/store.py`` (0600 file) and never appear
in a Device, an API answer or a log line. Live video is served by the hub as
JPEG snapshots and an MJPEG relay (``server.py``); the phone never needs the
camera's password in hub mode.

Capabilities: ``videoStream`` always; ``ptz`` only if the camera reports it.
"""
from __future__ import annotations

import concurrent.futures
import socket
import subprocess
import threading
import time
from typing import Any, Iterator
from urllib.parse import urlparse

from .. import capabilities as cap
from ..camera import media, onvif
from ..camera import store as camstore
from ..models import Device, DiscoveredHost
from .base import DeviceAdapter

C = cap.CapabilityInstance
DEFAULT_MOVE_MS = 500


def _tcp_ok(host: str, port: int, timeout: float = 1.2) -> bool:
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


def _host_port(cfg: dict[str, Any]) -> tuple[str | None, int]:
    for key in ("rtspUrl", "snapshotUrl", "mjpegUrl", "onvifUrl"):
        u = cfg.get(key)
        if u:
            return urlparse(u).hostname, media.default_port(u)
    return cfg.get("host"), 554


def _num(params: dict[str, Any], key: str, lo: float, hi: float, default: float | None = None) -> float:
    v = params.get(key, default)
    if v is None or isinstance(v, bool) or not isinstance(v, (int, float)):
        raise ValueError(f"'{key}' must be a number {lo}..{hi}")
    if not lo <= v <= hi:
        raise ValueError(f"'{key}' must be within {lo}..{hi}")
    return float(v)


class CameraAdapter(DeviceAdapter):
    id = "camera"
    name = "IP camera (ONVIF / RTSP / MJPEG)"
    is_cloud = False
    hidden = True          # not listed under /integrations (has /cameras instead)

    def __init__(self) -> None:
        self._stop_timers: dict[str, threading.Timer] = {}

    # The manager treats adapters with enabled() as optional integrations.
    def enabled(self) -> bool:
        return True

    def matches(self, host: DiscoveredHost) -> bool:  # cameras are added explicitly
        return False

    def build_device(self, host: DiscoveredHost) -> Device:  # pragma: no cover
        raise NotImplementedError("camera devices are built from the camera list")

    # ---- device model ----------------------------------------------------------------
    def device_from_config(self, cfg: dict[str, Any], reachable: bool | None = None) -> Device:
        ptz = cfg.get("ptz") or {}
        profiles = cfg.get("profiles") or []
        has_snapshot = bool(cfg.get("snapshotUrl") or cfg.get("mjpegUrl") or cfg.get("rtspUrl"))
        caps: dict[str, C] = {
            cap.VIDEO_STREAM: C(
                cap.VIDEO_STREAM,
                ["selectProfile"] if len(profiles) > 1 and cfg.get("protocol") == "onvif" else [],
                {
                    "protocol": cfg.get("protocol", "rtsp"),
                    "rtspUrl": cfg.get("rtspUrl"),
                    "profiles": [{k: p.get(k) for k in ("token", "name", "width", "height", "codec")}
                                 for p in profiles],
                    "selectedProfile": cfg.get("selectedProfile"),
                    "snapshotAvailable": has_snapshot,
                    "mjpegAvailable": bool(has_snapshot and (cfg.get("mjpegUrl") or cfg.get("snapshotUrl")
                                                            or media.ffmpeg_path())),
                    "audio": None,
                },
            )
        }
        if ptz.get("panTilt") or ptz.get("zoom"):
            caps[cap.PTZ] = C(cap.PTZ, ["move", "stop", *(["gotoPreset"] if ptz.get("presets") else [])], {
                "panTilt": bool(ptz.get("panTilt")), "zoom": bool(ptz.get("zoom")),
                "presets": list(ptz.get("presets") or []),
            })
        meta: dict[str, Any] = {"model": cfg.get("model"), "protocol": cfg.get("protocol"),
                                "match": {"ip": cfg.get("host"), "name": cfg.get("name")}}
        if cfg.get("room"):
            meta["room"] = cfg["room"]
        return Device(
            id=cfg["id"], name=cfg["name"], adapter=self.id, kind="camera", ip=cfg.get("host"),
            mac=cfg.get("mac"), vendor=cfg.get("vendor"),
            reachable=bool(reachable), controllable=True, capabilities=caps, meta=meta,
        )

    def list_devices(self) -> list[Device]:
        cfgs = camstore.list_cameras()
        if not cfgs:
            return []

        def probe(cfg: dict[str, Any]) -> bool:
            host, port = _host_port(cfg)
            return bool(host) and _tcp_ok(host, port)

        with concurrent.futures.ThreadPoolExecutor(max_workers=min(8, len(cfgs))) as ex:
            up = list(ex.map(probe, cfgs))
        return [self.device_from_config(c, r) for c, r in zip(cfgs, up)]

    def refresh_state(self, device: Device) -> None:
        cfg = camstore.get(device.id)
        if cfg:
            host, port = _host_port(cfg)
            device.reachable = bool(host) and _tcp_ok(host, port)

    # ---- adding / removing ------------------------------------------------------------
    def add_camera(self, body: dict[str, Any]) -> Device:
        """Validate, probe and store a camera. Raises ValueError (bad input),
        media.MediaError / onvif.OnvifError (camera problem, message is safe)."""
        name = (body.get("name") or "").strip() or "카메라"
        protocol = (body.get("protocol") or "").strip().lower()
        username = (body.get("username") or "").strip()
        password = body.get("password") or ""
        cfg: dict[str, Any] = {"id": camstore.new_id(), "name": name, "protocol": protocol,
                               "username": username, "password": password}
        if body.get("room"):
            cfg["room"] = str(body["room"]).strip()
        if protocol == "onvif":
            self._configure_onvif(cfg, str(body.get("address") or body.get("host") or ""))
        elif protocol == "rtsp":
            self._configure_rtsp(cfg, str(body.get("url") or ""), body.get("verify", True))
        elif protocol == "http":
            self._configure_http(cfg, str(body.get("url") or ""))
        else:
            raise ValueError("protocol must be one of: onvif, rtsp, http")
        camstore.put(cfg)
        return self.device_from_config(cfg, reachable=True)

    def remove_camera(self, cam_id: str) -> bool:
        return camstore.remove(cam_id)

    def _configure_onvif(self, cfg: dict[str, Any], address: str) -> None:
        if not address.strip():
            raise ValueError("camera address is required")
        url = onvif.normalize_device_url(address)
        cfg["onvifUrl"] = url
        cfg["host"] = urlparse(url).hostname
        client = onvif.OnvifClient(url, cfg["username"], cfg["password"])
        info = client.device_information()
        client.discover_services()
        profiles = client.profiles()
        cfg["vendor"] = info.get("Manufacturer")
        cfg["model"] = info.get("Model")
        best = next((p for p in profiles if (p.get("codec") or "").upper() == "H264"), profiles[0])
        cfg["profiles"] = [{k: p[k] for k in ("token", "name", "codec", "width", "height", "ptz")} for p in profiles]
        self._apply_profile(cfg, client, best["token"])
        if client.ptz_url and any(p.get("ptz") for p in profiles):
            try:
                presets = client.ptz_presets(cfg["selectedProfile"])
            except onvif.OnvifError:
                presets = []
            cfg["ptz"] = {"panTilt": True, "zoom": True, "presets": presets}

    @staticmethod
    def _apply_profile(cfg: dict[str, Any], client: onvif.OnvifClient, token: str) -> None:
        rtsp, _, _ = media.split_credentials(client.stream_uri(token))
        cfg["rtspUrl"] = rtsp
        snap = client.snapshot_uri(token)
        cfg["snapshotUrl"] = media.split_credentials(snap)[0] if snap else None
        cfg["selectedProfile"] = token

    def _configure_rtsp(self, cfg: dict[str, Any], url: str, verify: bool) -> None:
        url = url.strip()
        if not url.lower().startswith(("rtsp://", "rtsps://")):
            raise ValueError("RTSP address must start with rtsp://")
        clean, user, pw = media.split_credentials(url)   # accept rtsp://user:pass@host/...
        if user and not cfg["username"]:
            cfg["username"], cfg["password"] = user, pw or ""
        cfg["rtspUrl"] = clean
        cfg["host"] = urlparse(clean).hostname
        host, port = _host_port(cfg)
        if verify and not _tcp_ok(host, port, 3.0):
            raise media.MediaError(f"cannot connect to {host}:{port}")

    def _configure_http(self, cfg: dict[str, Any], url: str) -> None:
        url = url.strip()
        if not url.lower().startswith(("http://", "https://")):
            raise ValueError("address must start with http:// or https://")
        clean, user, pw = media.split_credentials(url)
        if user and not cfg["username"]:
            cfg["username"], cfg["password"] = user, pw or ""
        cfg["host"] = urlparse(clean).hostname
        r = media.http_get(clean, cfg["username"], cfg["password"], stream=True, timeout=8.0)
        try:
            ctype = (r.headers.get("Content-Type") or "").lower()
        finally:
            r.close()
        if "multipart" in ctype:
            cfg["mjpegUrl"] = clean
        elif "image/jpeg" in ctype or "image/jpg" in ctype:
            cfg["snapshotUrl"] = clean
        else:
            raise media.MediaError(f"URL is neither an MJPEG stream nor a JPEG snapshot (got '{ctype or 'unknown'}')")

    # ---- media -------------------------------------------------------------------------
    def _cfg(self, device: Device) -> dict[str, Any]:
        cfg = camstore.get(device.id)
        if cfg is None:
            raise LookupError(f"unknown camera {device.id}")
        return cfg

    @staticmethod
    def _rtsp_with_creds(cfg: dict[str, Any]) -> str:
        return media.with_credentials(cfg["rtspUrl"], cfg.get("username"), cfg.get("password"))

    def snapshot(self, device: Device) -> bytes:
        cfg = self._cfg(device)
        u, p = cfg.get("username"), cfg.get("password")
        if cfg.get("snapshotUrl"):
            return media.fetch_jpeg(cfg["snapshotUrl"], u, p)
        if cfg.get("mjpegUrl"):
            return media.mjpeg_first_frame(cfg["mjpegUrl"], u, p)
        if cfg.get("rtspUrl"):
            return media.rtsp_snapshot(self._rtsp_with_creds(cfg))
        raise media.MediaError("this camera has no snapshot source")

    def mjpeg_frames(self, device: Device, fps: int = 5) -> Iterator[bytes]:
        """Yield JPEG frames until the caller closes the generator."""
        cfg = self._cfg(device)
        u, p = cfg.get("username"), cfg.get("password")
        if cfg.get("mjpegUrl"):
            r = media.http_get(cfg["mjpegUrl"], u, p, stream=True, timeout=10.0)
            try:
                yield from media.iter_jpeg_frames(r.iter_content(chunk_size=8192))
            finally:
                r.close()
            return
        if cfg.get("rtspUrl") and media.ffmpeg_path():
            proc = subprocess.Popen(media.rtsp_to_mjpeg_cmd(self._rtsp_with_creds(cfg), fps=fps),
                                    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            try:
                def chunks() -> Iterator[bytes]:
                    while True:
                        b = proc.stdout.read1(65536)   # type: ignore[union-attr]
                        if not b:
                            return
                        yield b
                yield from media.iter_jpeg_frames(chunks())
            finally:
                proc.kill()
                proc.wait(timeout=5)
            return
        # Last resort: poll the snapshot URL (~2 fps).
        while True:
            t0 = time.monotonic()
            yield self.snapshot(device)
            time.sleep(max(0.0, 0.5 - (time.monotonic() - t0)))

    def stream_info(self, device: Device) -> dict[str, Any]:
        cfg = self._cfg(device)
        return {
            "rtspUrl": cfg.get("rtspUrl"),          # never contains credentials
            "requiresCredentials": bool(cfg.get("username")),
            "snapshotUrl": f"/devices/{device.id}/snapshot.jpg",
            "mjpegUrl": f"/devices/{device.id}/stream.mjpeg",
            "hlsUrl": None,                         # not built; see docs/cameras.md
            "ffmpeg": bool(media.ffmpeg_path()),
        }

    # ---- commands ------------------------------------------------------------------------
    def _onvif(self, cfg: dict[str, Any]) -> onvif.OnvifClient:
        if cfg.get("protocol") != "onvif":
            raise ValueError("this camera was added without ONVIF; PTZ is not available")
        c = onvif.OnvifClient(cfg["onvifUrl"], cfg.get("username", ""), cfg.get("password", ""))
        c.discover_services()
        return c

    def execute(self, device: Device, capability: str, action: str, params: dict[str, Any]) -> dict[str, Any]:
        cap.validate_action(capability, action)
        cfg = self._cfg(device)
        token = cfg.get("selectedProfile")
        try:
            if capability == cap.VIDEO_STREAM:       # selectProfile
                want = params.get("profile")
                if want not in [p["token"] for p in cfg.get("profiles") or []]:
                    raise ValueError("unknown profile")
                client = self._onvif(cfg)
                self._apply_profile(cfg, client, want)
                camstore.put(cfg)
                return {"ok": True, "profile": want}
            if capability == cap.PTZ:
                client = self._onvif(cfg)
                if action == "move":
                    pan = _num(params, "pan", -1, 1, 0)
                    tilt = _num(params, "tilt", -1, 1, 0)
                    zoom = _num(params, "zoom", -1, 1, 0)
                    ms = int(_num(params, "durationMs", 100, 5000, DEFAULT_MOVE_MS))
                    if not (pan or tilt or zoom):
                        raise ValueError("move needs a non-zero pan, tilt or zoom")
                    client.ptz_move(token, pan, tilt, zoom, ms / 1000)
                    self._schedule_stop(cfg, token, ms / 1000)
                    return {"ok": True}
                if action == "stop":
                    client.ptz_stop(token)
                    return {"ok": True}
                if action == "gotoPreset":
                    preset = params.get("preset")
                    if preset not in [p["token"] for p in (cfg.get("ptz") or {}).get("presets", [])]:
                        raise ValueError("unknown preset")
                    client.ptz_goto_preset(token, preset)
                    return {"ok": True}
        except onvif.OnvifAuthError as e:
            raise PermissionError(str(e)) from None
        raise ValueError(f"unsupported command {capability}.{action}")

    def _schedule_stop(self, cfg: dict[str, Any], token: str, delay: float) -> None:
        """Many cameras ignore the ContinuousMove timeout, so stop explicitly."""
        old = self._stop_timers.pop(cfg["id"], None)
        if old:
            old.cancel()

        def stop() -> None:
            try:
                self._onvif(cfg).ptz_stop(token)
            except Exception:  # noqa: BLE001 - best effort
                pass

        t = threading.Timer(delay + 0.2, stop)
        t.daemon = True
        self._stop_timers[cfg["id"]] = t
        t.start()

    def close(self) -> None:
        for t in self._stop_timers.values():
            t.cancel()
