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
    cap.WASHER: "washerOperatingState",
    cap.DRYER: "dryerOperatingState",
    cap.REFRIGERATION: "refrigeration",
    cap.CURTAIN: "windowShade",
    cap.ROOM_CLEANING: None,       # no standard ST capability (Samsung uses samsungce.* map extensions)
    cap.ZONE_CLEANING: None,
    cap.GO_TO: None,
    cap.FAN_SPEED: "robotCleanerTurboMode",   # coarse (on/off/silence) equivalent
    cap.MOPPING: None,
    cap.CONSUMABLES: None,
    cap.CLEANING_STATS: None,
    cap.VACUUM_MAP: None,
    cap.VIDEO_STREAM: "videoStream",   # ST cameras also expose imageCapture (snapshot)
    cap.PTZ: None,                     # no standard ST capability (vendor-specific)
}

# Secondary SmartThings capabilities the SmartThings adapter also ingests into a
# canonical capability (documentation + /capabilities output; the adapter holds
# the actual translation logic).
SMARTTHINGS_EXTRA: dict[str, list[str]] = {
    cap.VOLUME: ["audioMute"],
    cap.MEDIA_INPUT: ["samsungvd.mediaInputSource"],
    cap.MEDIA_PLAYBACK: ["mediaTrackControl"],
    cap.VACUUM: ["robotCleanerMovement", "robotCleanerCleaningMode", "battery"],
    cap.VIDEO_STREAM: ["imageCapture"],
    cap.WASHER: ["remoteControlStatus", "samsungce.washerOperatingState"],
    cap.DRYER: ["remoteControlStatus", "samsungce.dryerOperatingState"],
    cap.CURTAIN: ["windowShadeLevel"],
    cap.REFRIGERATION: [
        "temperatureMeasurement",
        "thermostatCoolingSetpoint",
        "contactSensor",
        "samsungce.powerCool",
        "samsungce.powerFreeze",
    ],
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
    cap.VACUUM: ("RvcOperationalState", 0x0061),   # + RvcRunMode 0x0054
    cap.SENSOR: None,                       # depends on concrete sensor cluster
    cap.WASHER: ("OperationalState", 0x0060),       # + LaundryWasherControls 0x0053
    cap.DRYER: ("OperationalState", 0x0060),        # + LaundryDryerControls 0x004A
    cap.REFRIGERATION: ("TemperatureControl", 0x0056),  # per-cabinet endpoint; + RefrigeratorAlarm 0x0057
    cap.CURTAIN: ("WindowCovering", 0x0102),           # UpOrOpen / DownOrClose / GoToLiftPercentage
    cap.ROOM_CLEANING: ("ServiceArea", 0x0150),        # SelectAreas + RvcRunMode cleaning
    cap.ZONE_CLEANING: None,                           # Matter has no free-form zones
    cap.GO_TO: None,
    cap.FAN_SPEED: ("RvcCleanMode", 0x0055),           # suction as clean-mode tags
    cap.MOPPING: ("RvcCleanMode", 0x0055),             # Mop / VacuumThenMop + intensity tags
    cap.CONSUMABLES: ("HepaFilterMonitoring", 0x0071),  # ResourceMonitoring family (filter); brushes: none
    cap.CLEANING_STATS: None,
    cap.VACUUM_MAP: None,                              # ServiceArea has area names, no raster map
    cap.VIDEO_STREAM: ("CameraAvStreamManagement", 0x0551),        # Matter 1.5 camera clusters
    cap.PTZ: ("CameraAvSettingsUserLevelManagement", 0x0552),      # MPTZ position / presets
}


def describe(capability_key: str) -> dict[str, object]:
    """Return the standard-mapping descriptor for a canonical capability."""
    st = SMARTTHINGS_MAP.get(capability_key)
    mt = MATTER_MAP.get(capability_key)
    return {
        "canonical": capability_key,
        "smartthings": st,
        "smartthingsExtra": SMARTTHINGS_EXTRA.get(capability_key, []),
        "matter": None if mt is None else {"cluster": mt[0], "id": hex(mt[1])},
    }


def full_matrix() -> list[dict[str, object]]:
    """The whole canonical<->standards matrix (handy for docs / debugging)."""
    return [describe(k) for k in cap.CANONICAL]
