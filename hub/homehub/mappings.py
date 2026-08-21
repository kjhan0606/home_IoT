"""Dual standard mappings for the canonical capability model.

Each canonical capability maps *out* to both a SmartThings capability and a
Matter cluster, so that when we later add a SmartThings-cloud adapter or a
Matter controller adapter, ingestion/exposure is a table lookup rather than a
rewrite. The mobile app never sees these — it only sees canonical capabilities.

Coverage note: Matter's media clusters are partial (e.g. no first-class TV
volume cluster in early revisions), which is exactly why TV-centric control
leans on SmartThings/local first. ``None`` means "no clean standard equivalent."
"""
from __future__ import annotations

from . import capabilities as cap


# canonical key -> SmartThings capability id
SMARTTHINGS_MAP: dict[str, str | None] = {
    cap.POWER: "switch",
    cap.VOLUME: "audioVolume",
    cap.CHANNEL: "tvChannel",
    cap.MEDIA_INPUT: "mediaInputSource",
    cap.MEDIA_PLAYBACK: "mediaPlayback",
    cap.LAUNCH_APP: "samsungvd.mediaInputSource",  # app launch via Samsung VD ext.
    cap.BRIGHTNESS: "switchLevel",
    cap.COLOR: "colorControl",
    cap.LOCK: "lock",
    cap.VACUUM: "robotCleanerMovement",
    cap.SENSOR: "sensor",
}

# canonical key -> Matter cluster (name, id). None where Matter has no clean fit.
MATTER_MAP: dict[str, tuple[str, int] | None] = {
    cap.POWER: ("OnOff", 0x0006),
    cap.VOLUME: None,                       # partial in early Matter revisions
    cap.CHANNEL: ("Channel", 0x0504),
    cap.MEDIA_INPUT: ("MediaInput", 0x0507),
    cap.MEDIA_PLAYBACK: ("MediaPlayback", 0x0506),
    cap.LAUNCH_APP: ("ApplicationLauncher", 0x050C),
    cap.BRIGHTNESS: ("LevelControl", 0x0008),
    cap.COLOR: ("ColorControl", 0x0300),
    cap.LOCK: ("DoorLock", 0x0101),
    cap.VACUUM: ("RvcRunMode", 0x0061),
    cap.SENSOR: None,                       # depends on concrete sensor cluster
}


def describe(capability_key: str) -> dict[str, object]:
    """Return the standard-mapping descriptor for a canonical capability."""
    st = SMARTTHINGS_MAP.get(capability_key)
    mt = MATTER_MAP.get(capability_key)
    return {
        "canonical": capability_key,
        "smartthings": st,
        "matter": None if mt is None else {"cluster": mt[0], "id": hex(mt[1])},
    }


def full_matrix() -> list[dict[str, object]]:
    """The whole canonical<->standards matrix (handy for docs / debugging)."""
    return [describe(k) for k in cap.CANONICAL]
