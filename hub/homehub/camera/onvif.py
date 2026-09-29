"""Minimal ONVIF client (SOAP over HTTP) + WS-Discovery.

Only what HomeHub needs: find cameras on the LAN, read device info, list media
profiles, get the RTSP stream URI and snapshot URI, and drive PTZ. Pure
``requests`` + ``xml.etree`` (no extra dependencies).

Authentication is WS-Security UsernameToken *PasswordDigest*. Cameras reject the
digest when their clock differs from ours, so ``OnvifClient`` reads the camera's
UTC time (``GetSystemDateAndTime``, which needs no login) and offsets ``Created``.

Nothing here logs or returns the password.
"""
from __future__ import annotations

import base64
import hashlib
import os
import re
import socket
import uuid
from datetime import datetime, timedelta, timezone
from typing import Any
from urllib.parse import unquote, urlparse
from xml.etree import ElementTree as ET

import requests

WS_DISCOVERY_ADDR = ("239.255.255.250", 3702)

NS_ENV = "http://www.w3.org/2003/05/soap-envelope"
NS_DEVICE = "http://www.onvif.org/ver10/device/wsdl"
NS_MEDIA = "http://www.onvif.org/ver10/media/wsdl"
NS_PTZ = "http://www.onvif.org/ver20/ptz/wsdl"
NS_SCHEMA = "http://www.onvif.org/ver10/schema"
NS_WSSE = "http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd"
NS_WSU = "http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd"
_PWD_DIGEST = "http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordDigest"
_NONCE_ENC = "http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-soap-message-security-1.0#Base64Binary"


class OnvifError(RuntimeError):
    """Transport, protocol or SOAP-fault failure talking to a camera."""


class OnvifAuthError(OnvifError):
    """The camera rejected the user name / password."""


# --- XML helpers (namespace-agnostic) ----------------------------------------
def _local(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def _findall(node: ET.Element, name: str) -> list[ET.Element]:
    return [e for e in node.iter() if _local(e.tag) == name]


def _find(node: ET.Element, name: str) -> ET.Element | None:
    for e in node.iter():
        if _local(e.tag) == name:
            return e
    return None


def _text(node: ET.Element | None, name: str) -> str | None:
    e = _find(node, name) if node is not None else None
    return (e.text or "").strip() or None if e is not None else None


def _esc(s: str) -> str:
    return (s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
            .replace('"', "&quot;"))


# --- WS-Discovery ------------------------------------------------------------
def _probe_message() -> bytes:
    return (
        '<?xml version="1.0" encoding="UTF-8"?>'
        '<e:Envelope xmlns:e="http://www.w3.org/2003/05/soap-envelope" '
        'xmlns:w="http://schemas.xmlsoap.org/ws/2004/08/addressing" '
        'xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery" '
        'xmlns:dn="http://www.onvif.org/ver10/network/wsdl">'
        f"<e:Header><w:MessageID>uuid:{uuid.uuid4()}</w:MessageID>"
        "<w:To>urn:schemas-xmlsoap-org:ws:2005:04:discovery</w:To>"
        "<w:Action>http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</w:Action></e:Header>"
        "<e:Body><d:Probe><d:Types>dn:NetworkVideoTransmitter</d:Types></d:Probe></e:Body>"
        "</e:Envelope>"
    ).encode()


def parse_probe_matches(xml: bytes | str, source_ip: str | None = None) -> list[dict[str, Any]]:
    """Parse one WS-Discovery ProbeMatches datagram into camera hints."""
    try:
        root = ET.fromstring(xml)
    except ET.ParseError:
        return []
    out = []
    for m in _findall(root, "ProbeMatch"):
        xaddrs = (_text(m, "XAddrs") or "").split()
        scopes = (_text(m, "Scopes") or "").split()
        info = {"name": None, "hardware": None, "location": None}
        for s in scopes:
            for key in info:
                prefix = f"onvif://www.onvif.org/{key}/"
                if s.lower().startswith(prefix):
                    info[key] = unquote(s[len(prefix):])
        host = source_ip
        for x in xaddrs:
            h = urlparse(x).hostname
            if h and not host:
                host = h
        out.append({
            "host": host,
            "xaddrs": xaddrs,
            "onvifUrl": next((x for x in xaddrs if urlparse(x).hostname == host), xaddrs[0] if xaddrs else None),
            "name": info["name"], "hardware": info["hardware"], "location": info["location"],
        })
    return out


def ws_discover(timeout: float = 3.0, bind_ip: str | None = None) -> list[dict[str, Any]]:
    """Multicast a WS-Discovery Probe for ONVIF cameras. Never raises."""
    found: dict[str, dict[str, Any]] = {}
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    try:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 2)
        if bind_ip:
            try:
                s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF, socket.inet_aton(bind_ip))
            except OSError:
                pass
        s.settimeout(timeout)
        s.sendto(_probe_message(), WS_DISCOVERY_ADDR)
        while True:
            try:
                data, addr = s.recvfrom(65507)
            except socket.timeout:
                break
            for m in parse_probe_matches(data, addr[0]):
                if m["host"] and m["host"] not in found:
                    found[m["host"]] = m
    except OSError:
        pass
    finally:
        s.close()
    return list(found.values())


# --- SOAP client -------------------------------------------------------------
class OnvifClient:
    def __init__(self, device_url: str, username: str = "", password: str = "",
                 timeout: float = 6.0, session: requests.Session | None = None) -> None:
        self.device_url = device_url
        self.username = username
        self.password = password
        self.timeout = timeout
        self._http = session or requests.Session()
        self._clock_offset = timedelta(0)
        self._clock_synced = False
        self.media_url: str | None = None
        self.ptz_url: str | None = None

    # -- low level --
    def _security(self) -> str:
        if not self.username:
            return ""
        nonce = os.urandom(16)
        created = (datetime.now(timezone.utc) + self._clock_offset).strftime("%Y-%m-%dT%H:%M:%SZ")
        digest = base64.b64encode(
            hashlib.sha1(nonce + created.encode() + self.password.encode()).digest()).decode()
        return (
            f'<Security xmlns="{NS_WSSE}" xmlns:s="{NS_ENV}" s:mustUnderstand="1"><UsernameToken>'
            f"<Username>{_esc(self.username)}</Username>"
            f'<Password Type="{_PWD_DIGEST}">{digest}</Password>'
            f'<Nonce EncodingType="{_NONCE_ENC}">{base64.b64encode(nonce).decode()}</Nonce>'
            f'<Created xmlns="{NS_WSU}">{created}</Created></UsernameToken></Security>'
        )

    def _call(self, url: str, body: str, *, auth: bool = True) -> ET.Element:
        header = f"<s:Header>{self._security()}</s:Header>" if auth and self.username else ""
        env = (f'<?xml version="1.0" encoding="UTF-8"?><s:Envelope xmlns:s="{NS_ENV}" '
               f'xmlns:tt="{NS_SCHEMA}" xmlns:tds="{NS_DEVICE}" xmlns:trt="{NS_MEDIA}" '
               f'xmlns:tptz="{NS_PTZ}">{header}<s:Body>{body}</s:Body></s:Envelope>')
        try:
            r = self._http.post(url, data=env.encode(), timeout=self.timeout,
                                headers={"Content-Type": "application/soap+xml; charset=utf-8"})
        except requests.RequestException as e:
            raise OnvifError(f"cannot reach camera at {urlparse(url).netloc}: {type(e).__name__}") from None
        if r.status_code == 401:
            raise OnvifAuthError("camera rejected the user name or password")
        try:
            root = ET.fromstring(r.content)
        except ET.ParseError:
            raise OnvifError(f"camera returned a non-SOAP answer (HTTP {r.status_code})") from None
        fault = _find(root, "Fault")
        if fault is not None:
            reason = _text(fault, "Text") or "SOAP fault"
            code = " ".join((e.text or "") for e in _findall(fault, "Value"))
            if "NotAuthorized" in code or "not authorized" in reason.lower() or "unauthorized" in reason.lower():
                raise OnvifAuthError("camera rejected the user name or password")
            raise OnvifError(f"camera error: {reason}")
        if r.status_code >= 400:
            raise OnvifError(f"camera answered HTTP {r.status_code}")
        return root

    # -- device service --
    def sync_clock(self) -> None:
        """Offset WS-Security timestamps to the camera's clock (best effort)."""
        if self._clock_synced:
            return
        self._clock_synced = True
        try:
            root = self._call(self.device_url, "<tds:GetSystemDateAndTime/>", auth=False)
            utc = _find(root, "UTCDateTime")
            if utc is None:
                return
            def n(name: str) -> int:
                return int(_text(utc, name) or 0)
            cam = datetime(n("Year"), n("Month"), n("Day"), n("Hour"), n("Minute"), n("Second"),
                           tzinfo=timezone.utc)
            self._clock_offset = cam - datetime.now(timezone.utc)
        except (OnvifError, ValueError):
            pass

    def device_information(self) -> dict[str, str | None]:
        self.sync_clock()
        root = self._call(self.device_url, "<tds:GetDeviceInformation/>")
        return {k: _text(root, k) for k in
                ("Manufacturer", "Model", "FirmwareVersion", "SerialNumber", "HardwareId")}

    def discover_services(self) -> None:
        """Fill ``media_url`` / ``ptz_url`` from GetCapabilities."""
        self.sync_clock()
        root = self._call(
            self.device_url, "<tds:GetCapabilities><tds:Category>All</tds:Category></tds:GetCapabilities>")
        media = _find(root, "Media")
        ptz = _find(root, "PTZ")
        self.media_url = _text(media, "XAddr") if media is not None else None
        self.ptz_url = _text(ptz, "XAddr") if ptz is not None else None
        if not self.media_url:
            raise OnvifError("camera does not report an ONVIF media service")

    # -- media service --
    def profiles(self) -> list[dict[str, Any]]:
        if not self.media_url:
            self.discover_services()
        root = self._call(self.media_url, "<trt:GetProfiles/>")
        out = []
        for p in _findall(root, "Profiles"):
            token = p.attrib.get("token")
            if not token:
                continue
            venc = _find(p, "VideoEncoderConfiguration")
            res = _find(venc, "Resolution") if venc is not None else None
            out.append({
                "token": token,
                "name": _text(p, "Name") or token,
                "codec": _text(venc, "Encoding") if venc is not None else None,
                "width": int(_text(res, "Width") or 0) or None if res is not None else None,
                "height": int(_text(res, "Height") or 0) or None if res is not None else None,
                "ptz": _find(p, "PTZConfiguration") is not None,
            })
        if not out:
            raise OnvifError("camera reports no media profiles")
        return out

    def stream_uri(self, profile_token: str) -> str:
        root = self._call(
            self.media_url,
            "<trt:GetStreamUri><trt:StreamSetup><tt:Stream>RTP-Unicast</tt:Stream>"
            "<tt:Transport><tt:Protocol>RTSP</tt:Protocol></tt:Transport></trt:StreamSetup>"
            f"<trt:ProfileToken>{_esc(profile_token)}</trt:ProfileToken></trt:GetStreamUri>")
        uri = _text(root, "Uri")
        if not uri:
            raise OnvifError("camera returned no stream URI")
        return uri

    def snapshot_uri(self, profile_token: str) -> str | None:
        try:
            root = self._call(
                self.media_url,
                f"<trt:GetSnapshotUri><trt:ProfileToken>{_esc(profile_token)}</trt:ProfileToken></trt:GetSnapshotUri>")
        except OnvifAuthError:
            raise
        except OnvifError:
            return None          # snapshot is optional in ONVIF
        return _text(root, "Uri")

    # -- PTZ service --
    def _need_ptz(self) -> str:
        if not self.ptz_url:
            raise OnvifError("camera has no ONVIF PTZ service")
        return self.ptz_url

    def ptz_move(self, profile: str, pan: float, tilt: float, zoom: float, timeout_s: float | None = None) -> None:
        vel = ""
        if pan or tilt:
            vel += f'<tt:PanTilt x="{pan:.3f}" y="{tilt:.3f}"/>'
        if zoom:
            vel += f'<tt:Zoom x="{zoom:.3f}"/>'
        timeout = f"<tptz:Timeout>PT{timeout_s:.1f}S</tptz:Timeout>" if timeout_s else ""
        self._call(self._need_ptz(),
                   f"<tptz:ContinuousMove><tptz:ProfileToken>{_esc(profile)}</tptz:ProfileToken>"
                   f"<tptz:Velocity>{vel}</tptz:Velocity>{timeout}</tptz:ContinuousMove>")

    def ptz_stop(self, profile: str) -> None:
        self._call(self._need_ptz(),
                   f"<tptz:Stop><tptz:ProfileToken>{_esc(profile)}</tptz:ProfileToken>"
                   "<tptz:PanTilt>true</tptz:PanTilt><tptz:Zoom>true</tptz:Zoom></tptz:Stop>")

    def ptz_presets(self, profile: str) -> list[dict[str, str]]:
        root = self._call(self._need_ptz(),
                          f"<tptz:GetPresets><tptz:ProfileToken>{_esc(profile)}</tptz:ProfileToken></tptz:GetPresets>")
        out = []
        for p in _findall(root, "Preset"):
            tok = p.attrib.get("token")
            if tok:
                out.append({"token": tok, "name": _text(p, "Name") or tok})
        return out

    def ptz_goto_preset(self, profile: str, preset: str) -> None:
        self._call(self._need_ptz(),
                   f"<tptz:GotoPreset><tptz:ProfileToken>{_esc(profile)}</tptz:ProfileToken>"
                   f"<tptz:PresetToken>{_esc(preset)}</tptz:PresetToken></tptz:GotoPreset>")


def normalize_device_url(host_or_url: str) -> str:
    """``192.168.0.50`` / ``192.168.0.50:8080`` / full URL -> ONVIF device service URL."""
    s = host_or_url.strip()
    if not re.match(r"^https?://", s, re.I):
        s = f"http://{s}"
    u = urlparse(s)
    if not u.hostname:
        raise ValueError("invalid camera address")
    if u.path in ("", "/"):
        s = f"{u.scheme}://{u.netloc}/onvif/device_service"
    return s
