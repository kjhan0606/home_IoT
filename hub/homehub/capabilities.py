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
        actions={"start": {}, "pause": {}, "stop": {}, "dock": {}},
        state={"status": "cleaning|paused|docked|idle", "battery": "int 0..100"},
        ui_hint="vacuum-controls",
    ),
    SENSOR: CapabilitySpec(
        key=SENSOR,
        actions={},  # read-only
        state={"readings": "dict[str, number]"},
        ui_hint="readout",
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
