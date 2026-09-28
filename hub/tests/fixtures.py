"""Canned vendor API payloads (shapes follow the public API docs / SDK)."""

ST_BASE = "https://api.smartthings.com/v1"
LG_BASE = "https://api-kic.lgthinq.com"


def st_attr(value, unit=None):
    d = {"value": value}
    if unit:
        d["unit"] = unit
    return d


def st_component(cid, caps, categories=()):
    return {"id": cid, "capabilities": [{"id": c, "version": 1} for c in caps],
            "categories": [{"name": n} for n in categories]}


ST_TV = {
    "deviceId": "tv-1", "name": "Samsung TV", "label": "[TV] Samsung 8 Series (55)",
    "manufacturerName": "Samsung Electronics",
    "ocf": {"manufacturerName": "Samsung Electronics", "modelNumber": "UN55KS8500FXZA"},
    "components": [st_component("main", ["switch", "audioVolume", "audioMute", "tvChannel",
                                         "mediaInputSource", "mediaPlayback"], ["Television"])],
}
ST_TV_STATUS = {"components": {"main": {
    "switch": {"switch": st_attr("on")},
    "audioVolume": {"volume": st_attr(12, "%")},
    "audioMute": {"mute": st_attr("unmuted")},
    "tvChannel": {"tvChannel": st_attr("11")},
    "mediaInputSource": {"inputSource": st_attr("HDMI1"),
                         "supportedInputSources": st_attr(["digitalTv", "HDMI1", "HDMI2"])},
    "mediaPlayback": {"playbackStatus": st_attr("playing")},
}}}

ST_WASHER = {
    "deviceId": "washer-1", "label": "Washer", "manufacturerName": "Samsung Electronics",
    "components": [st_component("main", ["switch", "washerOperatingState", "remoteControlStatus",
                                         "samsungce.washerOperatingState"], ["Washer"])],
}


def st_washer_status(remote="true", machine="run"):
    return {"components": {"main": {
        "switch": {"switch": st_attr("on")},
        "washerOperatingState": {
            "machineState": st_attr(machine), "washerJobState": st_attr("rinse"),
            "completionTime": st_attr("2099-01-01T00:00:00Z"),
            "supportedMachineStates": st_attr(["stop", "run", "pause"]),
        },
        "remoteControlStatus": {"remoteControlEnabled": st_attr(remote)},
        "samsungce.washerOperatingState": {"remainingTime": st_attr(42, "min")},
    }}}


ST_DRYER = {
    "deviceId": "dryer-1", "label": "Dryer", "manufacturerName": "Samsung Electronics",
    "components": [st_component("main", ["dryerOperatingState", "remoteControlStatus"], ["Dryer"])],
}
ST_DRYER_STATUS = {"components": {"main": {
    "dryerOperatingState": {"machineState": st_attr("stop"), "dryerJobState": st_attr("none"),
                            "completionTime": st_attr("2020-01-01T00:00:00Z")},
    "remoteControlStatus": {"remoteControlEnabled": st_attr("false")},
}}}

ST_FRIDGE = {
    "deviceId": "fridge-1", "label": "Family Hub", "manufacturerName": "Samsung Electronics",
    "components": [
        st_component("main", ["contactSensor", "refrigeration", "temperatureMeasurement"], ["Refrigerator"]),
        st_component("cooler", ["contactSensor", "temperatureMeasurement", "thermostatCoolingSetpoint"]),
        st_component("freezer", ["contactSensor", "temperatureMeasurement", "thermostatCoolingSetpoint"]),
    ],
}
ST_FRIDGE_STATUS = {"components": {
    "main": {"contactSensor": {"contact": st_attr("closed")},
             "refrigeration": {"rapidCooling": st_attr("off"), "rapidFreezing": st_attr("on"),
                               "defrost": st_attr("off")}},
    "cooler": {"contactSensor": {"contact": st_attr("open")},
               "temperatureMeasurement": {"temperature": st_attr(4, "C")},
               "thermostatCoolingSetpoint": {"coolingSetpoint": st_attr(3, "C")}},
    "freezer": {"contactSensor": {"contact": st_attr("closed")},
                "temperatureMeasurement": {"temperature": st_attr(-18, "C")},
                "thermostatCoolingSetpoint": {"coolingSetpoint": st_attr(-19, "C")}},
}}

ST_VACUUM = {
    "deviceId": "vac-1", "label": "Jet Bot", "manufacturerName": "Samsung Electronics",
    "components": [st_component("main", ["robotCleanerMovement", "robotCleanerCleaningMode", "battery"],
                                ["RobotCleaner"])],
}
ST_VACUUM_STATUS = {"components": {"main": {
    "robotCleanerMovement": {"robotCleanerMovement": st_attr("charging")},
    "robotCleanerCleaningMode": {"robotCleanerCleaningMode": st_attr("auto")},
    "battery": {"battery": st_attr(87, "%")},
}}}

# ---------------------------------------------------------------- LG ThinQ --


def lg_env(response):
    return {"messageId": "abc", "timestamp": "2026-09-28T00:00:00Z", "response": response}


LG_DEVICES = [
    {"deviceId": "lg-washer", "deviceInfo": {"deviceType": "DEVICE_WASHER", "modelName": "F24V", "alias": "LG Washer", "reportable": True}},
    {"deviceId": "lg-dryer", "deviceInfo": {"deviceType": "DEVICE_DRYER", "modelName": "RH10", "alias": "LG Dryer", "reportable": True}},
    {"deviceId": "lg-fridge", "deviceInfo": {"deviceType": "DEVICE_REFRIGERATOR", "modelName": "M874", "alias": "LG Fridge", "reportable": True}},
    {"deviceId": "lg-robot", "deviceInfo": {"deviceType": "DEVICE_ROBOT_CLEANER", "modelName": "R9", "alias": "CordZero", "reportable": True}},
    {"deviceId": "lg-styler", "deviceInfo": {"deviceType": "DEVICE_STYLER", "modelName": "S5", "alias": "Styler", "reportable": True}},
]


def _enum_w(values):
    return {"type": "enum", "mode": ["r", "w"], "value": {"r": values, "w": values}}


def lg_laundry_profile(mode_key):
    return {"property": [{
        "location": {"locationName": "MAIN"},
        "runState": {"currentState": {"type": "enum", "mode": ["r"], "value": {"r": ["RUNNING", "PAUSE", "END"]}}},
        "operation": {mode_key: {"type": "enum", "mode": ["w"], "value": {"w": ["START", "STOP", "POWER_OFF"]}}},
        "remoteControlEnable": {"remoteControlEnabled": {"type": "boolean", "mode": ["r"]}},
    }]}


def lg_laundry_state(current="RUNNING", remote=True):
    return [{
        "location": {"locationName": "MAIN"},
        "runState": {"currentState": current},
        "remoteControlEnable": {"remoteControlEnabled": remote},
        "timer": {"remainHour": 1, "remainMinute": 5, "totalHour": 2, "totalMinute": 0},
    }]


LG_FRIDGE_PROFILE = {"property": {
    "doorStatus": [{"locationName": "MAIN", "doorState": {"type": "enum", "mode": ["r"], "value": {"r": ["OPEN", "CLOSE"]}}}],
    "temperatureInUnits": [
        {"locationName": "FRIDGE", "targetTemperatureC": {"type": "range", "mode": ["r", "w"], "value": {"w": {"min": 1, "max": 7, "step": 1}}},
         "unit": {"type": "enum", "mode": ["r"], "value": {"r": ["C", "F"]}}},
        {"locationName": "FREEZER", "targetTemperatureC": {"type": "range", "mode": ["r", "w"], "value": {"w": {"min": -23, "max": -15, "step": 1}}}},
    ],
    "refrigeration": {"rapidFreeze": {"type": "boolean", "mode": ["r", "w"]},
                      "expressFridge": {"type": "boolean", "mode": ["r", "w"]}},
}}
LG_FRIDGE_STATE = {
    "doorStatus": [{"locationName": "MAIN", "doorState": "OPEN"}],
    "temperatureInUnits": [{"locationName": "FRIDGE", "targetTemperatureC": 3, "unit": "C"},
                           {"locationName": "FREEZER", "targetTemperatureC": -20, "unit": "C"}],
    "refrigeration": {"rapidFreeze": False, "expressFridge": True},
}

LG_ROBOT_PROFILE = {"property": {
    "runState": {"currentState": {"type": "enum", "mode": ["r"], "value": {"r": ["CLEANING", "PAUSE", "SLEEP"]}}},
    "robotCleanerJobMode": {"currentJobMode": {"type": "enum", "mode": ["r"], "value": {"r": ["ZIGZAG", "SECTOR_BASE"]}}},
    "operation": {"cleanOperationMode": {"type": "enum", "mode": ["w"], "value": {"w": ["START", "PAUSE", "HOMING", "RESUME", "WAKE_UP"]}}},
    "battery": {"percent": {"type": "range", "mode": ["r"]}},
}}


def lg_robot_state(current="PAUSE"):
    return {"runState": {"currentState": current}, "battery": {"level": "HIGH", "percent": 76},
            "robotCleanerJobMode": {"currentJobMode": "ZIGZAG"}}
