"""Camera media helpers: URL hygiene, authenticated snapshot fetch, ffmpeg.

Rules
  * Credentials never live inside stored/returned URLs; ``split_credentials`` /
    ``with_credentials`` move them in and out at the last moment.
  * ``redact`` is for logs and error text.
  * ffmpeg is optional. Without it the hub still serves HTTP snapshots and the
    RTSP URI, but cannot relay RTSP as MJPEG or grab a frame from RTSP.
"""
from __future__ import annotations

import shutil
import subprocess
from typing import Iterator
from urllib.parse import quote, unquote, urlparse, urlunparse

import requests
from requests.auth import HTTPBasicAuth, HTTPDigestAuth

JPEG_SOI = b"\xff\xd8"
JPEG_EOI = b"\xff\xd9"
MAX_FRAME_BYTES = 8 * 1024 * 1024


class MediaError(RuntimeError):
    """A snapshot/stream could not be produced (message is safe to show)."""


# --- URLs ----------------------------------------------------------------------
def split_credentials(url: str) -> tuple[str, str | None, str | None]:
    """``rtsp://u:p@host/x`` -> (``rtsp://host/x``, ``u``, ``p``)."""
    u = urlparse(url.strip())
    if not u.hostname:
        raise ValueError("invalid URL")
    if u.username is None and u.password is None:
        return url.strip(), None, None
    host = u.hostname if ":" not in u.hostname else f"[{u.hostname}]"
    netloc = host + (f":{u.port}" if u.port else "")
    clean = urlunparse((u.scheme, netloc, u.path, u.params, u.query, u.fragment))
    return clean, unquote(u.username or "") or None, unquote(u.password or "") or None


def with_credentials(url: str, username: str | None, password: str | None) -> str:
    if not username:
        return url
    u = urlparse(url)
    host = u.hostname or ""
    if ":" in host:
        host = f"[{host}]"
    auth = quote(username, safe="") + (f":{quote(password or '', safe='')}" if password else "")
    netloc = f"{auth}@{host}" + (f":{u.port}" if u.port else "")
    return urlunparse((u.scheme, netloc, u.path, u.params, u.query, u.fragment))


def redact(text: str) -> str:
    """Hide ``user:pass@`` in any URL inside ``text``."""
    import re
    return re.sub(r"(\w+://)[^/@\s]+@", r"\1***@", text)


def default_port(url: str) -> int:
    u = urlparse(url)
    return u.port or {"rtsp": 554, "rtsps": 322, "http": 80, "https": 443}.get(u.scheme, 80)


# --- HTTP with Basic/Digest ----------------------------------------------------------
def _auth_for(resp: requests.Response, username: str, password: str):
    hdr = resp.headers.get("WWW-Authenticate", "").lower()
    return HTTPDigestAuth(username, password) if "digest" in hdr else HTTPBasicAuth(username, password)


def http_get(url: str, username: str | None, password: str | None, *, timeout: float = 6.0,
             stream: bool = False, session: requests.Session | None = None) -> requests.Response:
    """GET that transparently answers a Basic or Digest challenge (cameras use both)."""
    s = session or requests.Session()
    try:
        r = s.get(url, timeout=timeout, stream=stream)
        if r.status_code == 401 and username:
            r.close()
            r = s.get(url, timeout=timeout, stream=stream, auth=_auth_for(r, username, password or ""))
    except requests.RequestException as e:
        raise MediaError(f"cannot reach camera: {type(e).__name__}") from None
    if r.status_code == 401:
        r.close()
        raise MediaError("camera rejected the user name or password")
    if r.status_code >= 400:
        r.close()
        raise MediaError(f"camera answered HTTP {r.status_code}")
    return r


def fetch_jpeg(url: str, username: str | None, password: str | None, timeout: float = 6.0) -> bytes:
    r = http_get(url, username, password, timeout=timeout)
    try:
        data = r.content[:MAX_FRAME_BYTES]
    finally:
        r.close()
    if not data.startswith(JPEG_SOI):
        raise MediaError("camera snapshot is not a JPEG image")
    return data


# --- MJPEG parsing -----------------------------------------------------------------
def iter_jpeg_frames(chunks: Iterator[bytes]) -> Iterator[bytes]:
    """Split a byte stream (multipart MJPEG, boundary-agnostic) into JPEG frames
    by scanning for SOI/EOI markers."""
    buf = bytearray()
    while True:
        try:
            chunk = next(chunks)
        except StopIteration:
            return
        if not chunk:
            continue
        buf += chunk
        while True:
            s = buf.find(JPEG_SOI)
            if s < 0:
                buf.clear()
                break
            e = buf.find(JPEG_EOI, s + 2)
            if e < 0:
                if s > 0:
                    del buf[:s]
                if len(buf) > MAX_FRAME_BYTES:
                    buf.clear()
                break
            yield bytes(buf[s:e + 2])
            del buf[:e + 2]


def mjpeg_first_frame(url: str, username: str | None, password: str | None, timeout: float = 8.0) -> bytes:
    r = http_get(url, username, password, timeout=timeout, stream=True)
    try:
        for frame in iter_jpeg_frames(r.iter_content(chunk_size=8192)):
            return frame
    except requests.RequestException as e:
        raise MediaError(f"camera stream interrupted: {type(e).__name__}") from None
    finally:
        r.close()
    raise MediaError("camera stream ended without a picture")


def multipart_frame(jpeg: bytes, boundary: str = "frame") -> bytes:
    return (f"--{boundary}\r\nContent-Type: image/jpeg\r\nContent-Length: {len(jpeg)}\r\n\r\n".encode()
            + jpeg + b"\r\n")


MJPEG_MEDIA_TYPE = "multipart/x-mixed-replace; boundary=frame"


# --- ffmpeg (optional) -------------------------------------------------------------------
def ffmpeg_path() -> str | None:
    return shutil.which("ffmpeg")


def _rtsp_input_args(url: str) -> list[str]:
    # TCP is far more reliable through Wi-Fi than UDP; -stimeout/-timeout in µs.
    return ["-rtsp_transport", "tcp", "-timeout", "8000000", "-i", url]


def rtsp_snapshot(url: str, timeout: float = 12.0) -> bytes:
    """One JPEG frame from an RTSP URL (URL may contain credentials)."""
    ff = ffmpeg_path()
    if not ff:
        raise MediaError("ffmpeg is not installed on the hub; cannot take a snapshot from an RTSP stream")
    cmd = [ff, "-hide_banner", "-loglevel", "error", *_rtsp_input_args(url),
           "-frames:v", "1", "-f", "image2pipe", "-vcodec", "mjpeg", "-q:v", "3", "pipe:1"]
    try:
        p = subprocess.run(cmd, capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        raise MediaError("camera did not deliver a picture in time") from None
    if p.returncode != 0 or not p.stdout.startswith(JPEG_SOI):
        raise MediaError("could not read a picture from the RTSP stream: "
                         + redact(p.stderr.decode("utf-8", "replace").strip()[-200:]))
    return p.stdout


def rtsp_to_mjpeg_cmd(url: str, fps: int = 5, width: int = 960) -> list[str]:
    ff = ffmpeg_path()
    if not ff:
        raise MediaError("ffmpeg is not installed on the hub")
    return [ff, "-hide_banner", "-loglevel", "error", *_rtsp_input_args(url), "-an",
            "-vf", f"fps={fps},scale='min({width},iw)':-2", "-q:v", "5",
            "-f", "mpjpeg", "-boundary_tag", "frame", "pipe:1"]
