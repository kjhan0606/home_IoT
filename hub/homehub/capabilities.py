"""Canonical capability model.

This is HomeHub's *neutral* vocabulary for what a device can do. Adapters
(local Samsung, later SmartThings-cloud, Matter, Roborock, ...) all normalize
into these capabilities, and the mobile app renders a widget per capability
without knowing the underlying brand/protocol.

Standard-vocabulary mappings (SmartThings capabilities, Matter clusters) live
in ``mappings.py`` and reference the keys defined here.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any


# --- Canonical capability keys ------------------------------------------------
POWER = "power"
VOLUME = "volume"
CHANNEL = "channel"
MEDIA_INPUT = "mediaInput"
MEDIA_PLAYBACK = "mediaPlayback"
LAUNCH_APP = "launchApp"
BRIGHTNESS = "brightness"
COLOR = "color"
LOCK = "lock"
VACUUM = "vacuum"
SENSOR = "sensor"
WASHER = "washer"
DRYER = "dryer"
REFRIGERATION = "refrigeration"
# Curtain / blind / shade (open, close, stop, position). Lights need no capability of their
# own: a light is `kind == "light"` + `power` (+ `brightness`/`color`) -- see docs/home-automation.md.
CURTAIN = "curtain"
# Robot-vacuum extensions (brand-neutral; coordinates are the device's *map*
# coordinates — GET /devices/{id}/map returns the pixel<->map transform).
ROOM_CLEANING = "roomCleaning"
ZONE_CLEANING = "zoneCleaning"
GO_TO = "goTo"
FAN_SPEED = "fanSpeed"
MOPPING = "mopping"
CONSUMABLES = "consumables"
CLEANING_STATS = "cleaningStats"
VACUUM_MAP = "vacuumMap"
# IP camera / CCTV (brand-neutral; ONVIF, RTSP and MJPEG cameras all map here).
# Camera credentials are NEVER part of any state: they live in the hub's 0600
# secret store (hub) or the phone's Keychain/Keystore (direct mode).
VIDEO_STREAM = "videoStream"
PTZ = "ptz"


def _laundry_spec(key: str) -> "CapabilitySpec":
    """Washer and dryer share one brand-neutral shape: a run/pause/stop machine
    with a job phase, remaining time and the appliance's remote-control flag.

    ``remoteControlEnabled`` mirrors the physical "Remote Start" switch on the
    appliance (SmartThings ``remoteControlStatus`` / LG ``remoteControlEnable``).
    Adapters MUST refuse ``start`` when it is False (safety rule of both vendors).
    """
    return CapabilitySpec(
        key=key,
        actions={"start": {}, "pause": {}, "stop": {}},
        state={
            "machineState": "run|pause|stop",
            "jobState": "str (vendor phase, lower-case, e.g. wash|rinse|spin|drying|none)",
            "remainingMinutes": "int|null",
            "completionTime": "iso8601|null",
            "remoteControlEnabled": "bool|null (null = unknown/not reported)",
        },
        ui_hint="laundry-cycle",
    )


@dataclass(frozen=True)
class CapabilitySpec:
    """Schema for one canonical capability: which actions it exposes and which
    state fields it carries. Used for validation and to tell the app how to
    render controls."""

    key: str
    actions: dict[str, dict[str, Any]]  # action name -> param schema ({} = no params)
    state: dict[str, str]               # state field -> type hint
    ui_hint: str                        # suggested widget family for the app


# --- The canonical registry ---------------------------------------------------
CANONICAL: dict[str, CapabilitySpec] = {
    POWER: CapabilitySpec(
        key=POWER,
        actions={"turnOn": {}, "turnOff": {}, "toggle": {}},
        state={"switch": "on|off"},
        ui_hint="toggle",
    ),
    VOLUME: CapabilitySpec(
        key=VOLUME,
        actions={
            "setLevel": {"level": "int 0..100"},
            "volumeUp": {},
            "volumeDown": {},
            "mute": {},
            "unmute": {},
        },
        state={"level": "int 0..100", "muted": "bool"},
        ui_hint="slider+mute",
    ),
    CHANNEL: CapabilitySpec(
        key=CHANNEL,
        actions={
            "channelUp": {},
            "channelDown": {},
            "setChannel": {"channel": "str|int"},
        },
        state={"channel": "str"},
        ui_hint="stepper",
    ),
    MEDIA_INPUT: CapabilitySpec(
        key=MEDIA_INPUT,
        actions={"select": {"source": "str (one of sources)"}},
        state={"sources": "list[str]", "selected": "str"},
        ui_hint="picker",
    ),
    MEDIA_PLAYBACK: CapabilitySpec(
        key=MEDIA_PLAYBACK,
        actions={"play": {}, "pause": {}, "stop": {}, "next": {}, "previous": {}},
        state={"status": "playing|paused|stopped"},
        ui_hint="transport",
    ),
    LAUNCH_APP: CapabilitySpec(
        key=LAUNCH_APP,
        actions={"open": {"app": "str (one of apps)"}},
        state={"apps": "list[str]"},
        ui_hint="app-grid",
    ),
    BRIGHTNESS: CapabilitySpec(
        key=BRIGHTNESS,
        actions={"setLevel": {"level": "int 0..100"}},
        state={"level": "int 0..100"},
        ui_hint="slider",
    ),
    COLOR: CapabilitySpec(
        key=COLOR,
        actions={
            "setColor": {"hue": "int 0..360", "saturation": "int 0..100"},
            "setColorTemperature": {"kelvin": "int"},
        },
        state={"hue": "int", "saturation": "int", "kelvin": "int"},
        ui_hint="color-wheel",
    ),
    LOCK: CapabilitySpec(
        key=LOCK,
        actions={"lock": {}, "unlock": {}},
        state={"locked": "bool"},
        ui_hint="toggle",
    ),
    VACUUM: CapabilitySpec(
        key=VACUUM,
        actions={
            "start": {},          # also resumes when paused
            "pause": {},
            "stop": {},
            "dock": {},
            "setCleaningMode": {"mode": "str (one of cleaningModes)"},
        },
        state={
            "status": "cleaning|paused|returning|charging|docked|moving|idle|error",
            "battery": "int 0..100",
            "cleaningMode": "str|null",
            "cleaningModes": "list[str]",
            "error": "str|null (robot error code name; null = no error)",
            "dockError": "str|null",
        },
        ui_hint="vacuum-controls",
    ),
    SENSOR: CapabilitySpec(
        key=SENSOR,
        actions={},  # read-only
        state={"readings": "dict[str, number]"},
        ui_hint="readout",
    ),
    WASHER: _laundry_spec(WASHER),
    DRYER: _laundry_spec(DRYER),
    REFRIGERATION: CapabilitySpec(
        key=REFRIGERATION,
        actions={
            "setFridgeSetpoint": {"temperature": "number (in state.unit)"},
            "setFreezerSetpoint": {"temperature": "number (in state.unit)"},
            "setRapidCooling": {"enabled": "bool"},
            "setRapidFreezing": {"enabled": "bool"},
        },
        state={
            "unit": "C|F",
            "fridgeTemperature": "number|null (measured)",
            "freezerTemperature": "number|null (measured)",
            "fridgeSetpoint": "number|null",
            "freezerSetpoint": "number|null",
            "doorOpen": "bool|null (any door open)",
            "doors": "dict[str, bool] (per-compartment open flags)",
            "rapidCooling": "bool|null",
            "rapidFreezing": "bool|null",
        },
        ui_hint="fridge-panel",
    ),
    CURTAIN: CapabilitySpec(
        key=CURTAIN,
        actions={
            "open": {},
            "close": {},
            "stop": {},
            "setPosition": {"position": "int 0..100 (100 = fully open, 0 = fully closed)"},
        },
        state={
            "position": "int 0..100|null (100 = fully open, 0 = fully closed; null = unknown)",
            "status": "open|closed|opening|closing|partial|unknown",
        },
        ui_hint="curtain-controls",
    ),
    ROOM_CLEANING: CapabilitySpec(
        key=ROOM_CLEANING,
        actions={"cleanRooms": {"roomIds": "list[str] (ids from state.rooms)", "repeat": "int 1..maxRepeat (default 1)"}},
        state={"rooms": "list[{id: str, name: str}]", "maxRepeat": "int"},
        ui_hint="room-picker",
    ),
    ZONE_CLEANING: CapabilitySpec(
        key=ZONE_CLEANING,
        actions={"cleanZones": {
            "zones": "list[[x1, y1, x2, y2]] (map coordinates)",
            "repeat": "int 1..maxRepeat (default 1)",
        }},
        state={"maxZones": "int", "maxRepeat": "int", "coordinateSpace": "map"},
        ui_hint="zone-drawer",
    ),
    GO_TO: CapabilitySpec(
        key=GO_TO,
        actions={"goTo": {"x": "number (map coordinates)", "y": "number (map coordinates)"}},
        state={"coordinateSpace": "map"},
        ui_hint="map-tap",
    ),
    FAN_SPEED: CapabilitySpec(
        key=FAN_SPEED,
        actions={"setLevel": {"level": "str (one of state.levels)"}},
        state={"level": "str|null", "levels": "list[str]"},
        ui_hint="picker",
    ),
    MOPPING: CapabilitySpec(
        key=MOPPING,
        actions={
            "setWaterLevel": {"level": "str (one of state.waterLevels)"},
            "setMopMode": {"mode": "str (one of state.mopModes)"},
        },
        state={
            "waterLevel": "str|null", "waterLevels": "list[str]",
            "mopMode": "str|null", "mopModes": "list[str]",
        },
        ui_hint="mop-controls",
    ),
    CONSUMABLES: CapabilitySpec(
        key=CONSUMABLES,
        actions={"reset": {"id": "str (one of state.items[].id with resettable=true)"}},
        state={"items": "list[{id, name, usedHours, remainingPercent, resettable}]"},
        ui_hint="consumables-list",
    ),
    CLEANING_STATS: CapabilitySpec(
        key=CLEANING_STATS,
        actions={},  # read-only
        state={"areaM2": "number|null (current/last run)", "durationSeconds": "int|null"},
        ui_hint="readout",
    ),
    VACUUM_MAP: CapabilitySpec(
        key=VACUUM_MAP,
        actions={},  # read-only; fetch GET /devices/{id}/map (JSON) or /map.png
        state={"available": "bool"},
        ui_hint="map-view",
    ),
    VIDEO_STREAM: CapabilitySpec(
        key=VIDEO_STREAM,
        # Live video / snapshot are fetched over media endpoints (hub:
        # GET /devices/{id}/snapshot.jpg | stream.mjpeg | stream), not commands.
        actions={"selectProfile": {"profile": "str (one of state.profiles[].token)"}},
        state={
            "protocol": "onvif|rtsp|mjpeg|demo (informational; the UI must not branch on it)",
            "rtspUrl": "str|null (credentials are never included)",
            "profiles": "list[{token, name, width, height, codec}]",
            "selectedProfile": "str|null",
            "snapshotAvailable": "bool",
            "mjpegAvailable": "bool (the hub can relay an MJPEG stream)",
            "audio": "bool|null",
        },
        ui_hint="camera-view",
    ),
    PTZ: CapabilitySpec(
        key=PTZ,
        actions={
            "move": {
                "pan": "number -1..1 (velocity, + = right)",
                "tilt": "number -1..1 (velocity, + = up)",
                "zoom": "number -1..1 (velocity, + = in)",
                "durationMs": "int 100..5000 (default 500; the camera stops by itself)",
            },
            "stop": {},
            "gotoPreset": {"preset": "str (one of state.presets[].token)"},
        },
        state={
            "panTilt": "bool",
            "zoom": "bool",
            "presets": "list[{token, name}]",
        },
        ui_hint="ptz-pad",
    ),
}


@dataclass
class CapabilityInstance:
    """A capability as it exists on a concrete device: its live state plus the
    subset of canonical actions this device actually supports."""

    key: str
    actions: list[str] = field(default_factory=list)
    state: dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        return {"key": self.key, "actions": self.actions, "state": self.state}

    @classmethod
    def from_dict(cls, d: dict[str, Any]) -> "CapabilityInstance":
        return cls(
            key=d["key"],
            actions=list(d.get("actions", [])),
            state=dict(d.get("state", {})),
        )


def validate_action(capability_key: str, action: str) -> None:
    """Raise ValueError if the action isn't part of the canonical capability."""
    spec = CANONICAL.get(capability_key)
    if spec is None:
        raise ValueError(f"unknown capability: {capability_key!r}")
    if action not in spec.actions:
        raise ValueError(
            f"action {action!r} not valid for capability {capability_key!r}; "
            f"valid: {sorted(spec.actions)}"
        )
