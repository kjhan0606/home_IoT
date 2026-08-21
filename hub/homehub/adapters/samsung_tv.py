"""Local Samsung Tizen TV adapter.

Control path (unofficial, local): Wake-on-LAN to power on + the Samsung
MultiScreen WebSocket remote (port 8002, token-authed) for everything else.
This is the MVP integration; the canonical contract it satisfies is identical
to what a future official SmartThings-cloud adapter will satisfy, so the app
and API never change when we swap it for App-Store compliance.
"""
from __future__ import annotations

from typing import Any

from .. import capabilities as cap
from .. import config
from ..models import Device, DiscoveredHost
from ..netutil import wake_on_lan
from .base import DeviceAdapter

# Canonical volume/channel actions -> Samsung remote key.
_KEYS = {
    ("volume", "volumeUp"): "KEY_VOLUP",
    ("volume", "volumeDown"): "KEY_VOLDOWN",
    ("volume", "mute"): "KEY_MUTE",
    ("volume", "unmute"): "KEY_MUTE",       # Samsung mute is a toggle
    ("channel", "channelUp"): "KEY_CHUP",
    ("channel", "channelDown"): "KEY_CHDOWN",
    ("power", "turnOff"): "KEY_POWER",
    ("power", "toggle"): "KEY_POWER",
}

# A couple of well-known Tizen app ids for launchApp when app_list() is empty.
_KNOWN_APPS = {
    "netflix": "11101200001",
    "youtube": "111299001912",
    "disney+": "3201901017640",
    "primevideo": "3201512006785",
}


class SamsungTVAdapter(DeviceAdapter):
    id = "samsung_local"
    name = "Samsung TV (local)"

    def __init__(self) -> None:
        self._clients: dict[str, Any] = {}     # device.id -> SamsungTVWS

    # --- discovery claim ------------------------------------------------------
    def matches(self, host: DiscoveredHost) -> bool:
        vendor = (host.vendor or "").lower()
        mfr = (host.extra.get("ssdp_info", {}) or {}).get("manufacturer", "").lower()
        samsung_hint = "samsung" in vendor or "samsung" in mfr
        mdns_hint = any("samsungmsf" in s for s in host.mdns_services)
        tv_ports = 8001 in host.open_ports or 8002 in host.open_ports
        return mdns_hint or (samsung_hint and tv_ports)

    # --- build canonical device ----------------------------------------------
    def build_device(self, host: DiscoveredHost) -> Device:
        name = host.hostname or "Samsung TV"
        model = None
        info = self._rest_info(host.ip)
        if info:
            dev = info.get("device", {})
            name = dev.get("name", name)
            model = dev.get("modelName")

        power_actions = ["turnOff", "toggle"]
        if host.mac:
            power_actions.insert(0, "turnOn")     # WoL needs the MAC

        caps = {
            cap.POWER: cap.CapabilityInstance(
                key=cap.POWER, actions=power_actions, state={"switch": "unknown"}
            ),
            cap.VOLUME: cap.CapabilityInstance(
                key=cap.VOLUME,
                actions=["volumeUp", "volumeDown", "mute", "unmute"],
                state={},
            ),
            cap.CHANNEL: cap.CapabilityInstance(
                key=cap.CHANNEL,
                actions=["channelUp", "channelDown", "setChannel"],
                state={},
            ),
            cap.MEDIA_INPUT: cap.CapabilityInstance(
                key=cap.MEDIA_INPUT,
                actions=["select"],
                state={"sources": ["source", "hdmi"], "selected": None},
            ),
            cap.LAUNCH_APP: cap.CapabilityInstance(
                key=cap.LAUNCH_APP,
                actions=["open"],
                state={"apps": sorted(_KNOWN_APPS)},
            ),
        }

        return Device(
            id=f"{self.id}:{host.mac or host.ip}",
            name=name,
            adapter=self.id,
            kind="tv",
            ip=host.ip,
            mac=host.mac,
            vendor=host.vendor or "Samsung",
            reachable=(8001 in host.open_ports or 8002 in host.open_ports),
            controllable=True,
            capabilities=caps,
            meta={"model": model, "tokenFile": str(self._token_path(host))},
        )

    # --- command execution ----------------------------------------------------
    def execute(
        self, device: Device, capability: str, action: str, params: dict[str, Any]
    ) -> dict[str, Any]:
        cap.validate_action(capability, action)

        # Power-on is out-of-band (TV's WS is asleep) -> Wake-on-LAN.
        if capability == cap.POWER and action == "turnOn":
            if not device.mac:
                raise RuntimeError("cannot power on: MAC unknown (needed for WoL)")
            sent = wake_on_lan(device.mac)
            return {"ok": True, "method": "wol", "packets": sent}

        # Direct key mappings.
        key = _KEYS.get((capability, action))
        if key:
            self._send_key(device, key)
            return {"ok": True, "method": "ws", "key": key}

        # Composite / parameterized actions.
        if capability == cap.CHANNEL and action == "setChannel":
            channel = str(params.get("channel", "")).strip()
            if not channel.isdigit():
                raise ValueError("setChannel requires a numeric 'channel'")
            for digit in channel:
                self._send_key(device, f"KEY_{digit}")
            self._send_key(device, "KEY_ENTER")
            return {"ok": True, "method": "ws", "channel": channel}

        if capability == cap.MEDIA_INPUT and action == "select":
            source = str(params.get("source", "source")).lower()
            self._send_key(device, "KEY_HDMI" if source == "hdmi" else "KEY_SOURCE")
            return {"ok": True, "method": "ws", "source": source}

        if capability == cap.LAUNCH_APP and action == "open":
            app = str(params.get("app", "")).strip()
            app_id = _KNOWN_APPS.get(app.lower(), app)
            self._client(device).run_app(app_id)
            return {"ok": True, "method": "ws", "app": app_id}

        raise ValueError(f"unsupported: {capability}.{action}")

    # --- state refresh --------------------------------------------------------
    def refresh_state(self, device: Device) -> None:
        info = self._rest_info(device.ip)
        power = device.capabilities.get(cap.POWER)
        if power is not None:
            power.state["switch"] = "on" if info else "off/standby"
        device.reachable = bool(info)

    # --- internals ------------------------------------------------------------
    def _token_path(self, host_or_dev) -> Any:
        key = getattr(host_or_dev, "mac", None) or getattr(host_or_dev, "ip", "tv")
        config.ensure_dirs()
        return config.TOKEN_DIR / f"samsung_{str(key).replace(':', '')}.txt"

    def _client(self, device: Device):
        if device.id not in self._clients:
            from samsungtvws import SamsungTVWS

            self._clients[device.id] = SamsungTVWS(
                host=device.ip,
                port=8002,
                token_file=device.meta.get("tokenFile") or str(self._token_path(device)),
                name=config.HUB_NAME,
                timeout=8,
            )
        return self._clients[device.id]

    def _send_key(self, device: Device, key: str) -> None:
        try:
            self._client(device).send_key(key)
        except Exception as e:  # noqa: BLE001 - surface a helpful hint
            raise RuntimeError(
                f"TV WebSocket command failed ({key}): {e}. "
                "If this is the first command, accept the 'Allow device?' "
                "prompt on the TV screen with the remote, then retry."
            ) from e

    def _rest_info(self, ip: str) -> dict | None:
        try:
            import requests

            r = requests.get(f"http://{ip}:8001/api/v2/", timeout=3)
            if r.status_code == 200:
                return r.json()
        except Exception:
            pass
        return None
