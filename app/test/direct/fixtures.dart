// Canned vendor payloads, ported from hub/tests/fixtures.py (shapes follow
// the public SmartThings / LG ThinQ Connect docs).
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const stBase = 'https://api.smartthings.com/v1';
const lgBase = 'https://api-kic.lgthinq.com';

Map<String, dynamic> stAttr(Object? value, [String? unit]) => {'value': value, 'unit': ?unit};

Map<String, dynamic> stComponent(String id, List<String> caps, [List<String> categories = const []]) => {
  'id': id,
  'capabilities': [
    for (final c in caps) {'id': c, 'version': 1},
  ],
  'categories': [
    for (final n in categories) {'name': n},
  ],
};

final stTv = <String, dynamic>{
  'deviceId': 'tv-1',
  'name': 'Samsung TV',
  'label': '[TV] Samsung 8 Series (55)',
  'manufacturerName': 'Samsung Electronics',
  'ocf': {'manufacturerName': 'Samsung Electronics', 'modelNumber': 'UN55KS8500FXZA'},
  'components': [
    stComponent(
      'main',
      ['switch', 'audioVolume', 'audioMute', 'tvChannel', 'mediaInputSource', 'mediaPlayback'],
      ['Television'],
    ),
  ],
};
final stTvStatus = <String, dynamic>{
  'components': {
    'main': {
      'switch': {'switch': stAttr('on')},
      'audioVolume': {'volume': stAttr(12, '%')},
      'audioMute': {'mute': stAttr('unmuted')},
      'tvChannel': {'tvChannel': stAttr('11')},
      'mediaInputSource': {
        'inputSource': stAttr('HDMI1'),
        'supportedInputSources': stAttr(['digitalTv', 'HDMI1', 'HDMI2']),
      },
      'mediaPlayback': {'playbackStatus': stAttr('playing')},
    },
  },
};

final stWasher = <String, dynamic>{
  'deviceId': 'washer-1',
  'label': 'Washer',
  'manufacturerName': 'Samsung Electronics',
  'components': [
    stComponent(
      'main',
      ['switch', 'washerOperatingState', 'remoteControlStatus', 'samsungce.washerOperatingState'],
      ['Washer'],
    ),
  ],
};

Map<String, dynamic> stWasherStatus({String remote = 'true', String machine = 'run'}) => {
  'components': {
    'main': {
      'switch': {'switch': stAttr('on')},
      'washerOperatingState': {
        'machineState': stAttr(machine),
        'washerJobState': stAttr('rinse'),
        'completionTime': stAttr('2099-01-01T00:00:00Z'),
        'supportedMachineStates': stAttr(['stop', 'run', 'pause']),
      },
      'remoteControlStatus': {'remoteControlEnabled': stAttr(remote)},
      'samsungce.washerOperatingState': {'remainingTime': stAttr(42, 'min')},
    },
  },
};

final stDryer = <String, dynamic>{
  'deviceId': 'dryer-1',
  'label': 'Dryer',
  'manufacturerName': 'Samsung Electronics',
  'components': [
    stComponent('main', ['dryerOperatingState', 'remoteControlStatus'], ['Dryer']),
  ],
};
final stDryerStatus = <String, dynamic>{
  'components': {
    'main': {
      'dryerOperatingState': {
        'machineState': stAttr('stop'),
        'dryerJobState': stAttr('none'),
        'completionTime': stAttr('2020-01-01T00:00:00Z'),
      },
      'remoteControlStatus': {'remoteControlEnabled': stAttr('false')},
    },
  },
};

final stFridge = <String, dynamic>{
  'deviceId': 'fridge-1',
  'label': 'Family Hub',
  'manufacturerName': 'Samsung Electronics',
  'components': [
    stComponent('main', ['contactSensor', 'refrigeration', 'temperatureMeasurement'], ['Refrigerator']),
    stComponent('cooler', ['contactSensor', 'temperatureMeasurement', 'thermostatCoolingSetpoint']),
    stComponent('freezer', ['contactSensor', 'temperatureMeasurement', 'thermostatCoolingSetpoint']),
  ],
};
final stFridgeStatus = <String, dynamic>{
  'components': {
    'main': {
      'contactSensor': {'contact': stAttr('closed')},
      'refrigeration': {'rapidCooling': stAttr('off'), 'rapidFreezing': stAttr('on'), 'defrost': stAttr('off')},
    },
    'cooler': {
      'contactSensor': {'contact': stAttr('open')},
      'temperatureMeasurement': {'temperature': stAttr(4, 'C')},
      'thermostatCoolingSetpoint': {'coolingSetpoint': stAttr(3, 'C')},
    },
    'freezer': {
      'contactSensor': {'contact': stAttr('closed')},
      'temperatureMeasurement': {'temperature': stAttr(-18, 'C')},
      'thermostatCoolingSetpoint': {'coolingSetpoint': stAttr(-19, 'C')},
    },
  },
};

final stVacuum = <String, dynamic>{
  'deviceId': 'vac-1',
  'label': 'Jet Bot',
  'manufacturerName': 'Samsung Electronics',
  'components': [
    stComponent('main', ['robotCleanerMovement', 'robotCleanerCleaningMode', 'battery'], ['RobotCleaner']),
  ],
};
final stVacuumStatus = <String, dynamic>{
  'components': {
    'main': {
      'robotCleanerMovement': {'robotCleanerMovement': stAttr('charging')},
      'robotCleanerCleaningMode': {'robotCleanerCleaningMode': stAttr('auto')},
      'battery': {'battery': stAttr(87, '%')},
    },
  },
};

// ---------------------------------------------------------------- LG ThinQ --
Map<String, dynamic> lgEnv(Object? response) => {
  'messageId': 'abc',
  'timestamp': '2026-09-28T00:00:00Z',
  'response': response,
};

Map<String, dynamic> _lgDev(String id, String type, String model, String alias) => {
  'deviceId': id,
  'deviceInfo': {'deviceType': type, 'modelName': model, 'alias': alias, 'reportable': true},
};

final lgDevices = [
  _lgDev('lg-washer', 'DEVICE_WASHER', 'F24V', 'LG Washer'),
  _lgDev('lg-dryer', 'DEVICE_DRYER', 'RH10', 'LG Dryer'),
  _lgDev('lg-fridge', 'DEVICE_REFRIGERATOR', 'M874', 'LG Fridge'),
  _lgDev('lg-robot', 'DEVICE_ROBOT_CLEANER', 'R9', 'CordZero'),
  _lgDev('lg-styler', 'DEVICE_STYLER', 'S5', 'Styler'),
];

Map<String, dynamic> lgLaundryProfile(String modeKey) => {
  'property': [
    {
      'location': {'locationName': 'MAIN'},
      'runState': {
        'currentState': {
          'type': 'enum',
          'mode': ['r'],
          'value': {
            'r': ['RUNNING', 'PAUSE', 'END'],
          },
        },
      },
      'operation': {
        modeKey: {
          'type': 'enum',
          'mode': ['w'],
          'value': {
            'w': ['START', 'STOP', 'POWER_OFF'],
          },
        },
      },
      'remoteControlEnable': {
        'remoteControlEnabled': {
          'type': 'boolean',
          'mode': ['r'],
        },
      },
    },
  ],
};

List<Map<String, dynamic>> lgLaundryState({String current = 'RUNNING', bool remote = true}) => [
  {
    'location': {'locationName': 'MAIN'},
    'runState': {'currentState': current},
    'remoteControlEnable': {'remoteControlEnabled': remote},
    'timer': {'remainHour': 1, 'remainMinute': 5, 'totalHour': 2, 'totalMinute': 0},
  },
];

final lgFridgeProfile = <String, dynamic>{
  'property': {
    'doorStatus': [
      {
        'locationName': 'MAIN',
        'doorState': {
          'type': 'enum',
          'mode': ['r'],
          'value': {
            'r': ['OPEN', 'CLOSE'],
          },
        },
      },
    ],
    'temperatureInUnits': [
      {
        'locationName': 'FRIDGE',
        'targetTemperatureC': {
          'type': 'range',
          'mode': ['r', 'w'],
          'value': {
            'w': {'min': 1, 'max': 7, 'step': 1},
          },
        },
        'unit': {
          'type': 'enum',
          'mode': ['r'],
          'value': {
            'r': ['C', 'F'],
          },
        },
      },
      {
        'locationName': 'FREEZER',
        'targetTemperatureC': {
          'type': 'range',
          'mode': ['r', 'w'],
          'value': {
            'w': {'min': -23, 'max': -15, 'step': 1},
          },
        },
      },
    ],
    'refrigeration': {
      'rapidFreeze': {
        'type': 'boolean',
        'mode': ['r', 'w'],
      },
      'expressFridge': {
        'type': 'boolean',
        'mode': ['r', 'w'],
      },
    },
  },
};
final lgFridgeState = <String, dynamic>{
  'doorStatus': [
    {'locationName': 'MAIN', 'doorState': 'OPEN'},
  ],
  'temperatureInUnits': [
    {'locationName': 'FRIDGE', 'targetTemperatureC': 3, 'unit': 'C'},
    {'locationName': 'FREEZER', 'targetTemperatureC': -20, 'unit': 'C'},
  ],
  'refrigeration': {'rapidFreeze': false, 'expressFridge': true},
};

final lgRobotProfile = <String, dynamic>{
  'property': {
    'runState': {
      'currentState': {
        'type': 'enum',
        'mode': ['r'],
        'value': {
          'r': ['CLEANING', 'PAUSE', 'SLEEP'],
        },
      },
    },
    'robotCleanerJobMode': {
      'currentJobMode': {
        'type': 'enum',
        'mode': ['r'],
        'value': {
          'r': ['ZIGZAG', 'SECTOR_BASE'],
        },
      },
    },
    'operation': {
      'cleanOperationMode': {
        'type': 'enum',
        'mode': ['w'],
        'value': {
          'w': ['START', 'PAUSE', 'HOMING', 'RESUME', 'WAKE_UP'],
        },
      },
    },
    'battery': {
      'percent': {
        'type': 'range',
        'mode': ['r'],
      },
    },
  },
};

Map<String, dynamic> lgRobotState({String current = 'PAUSE'}) => {
  'runState': {'currentState': current},
  'battery': {'level': 'HIGH', 'percent': 76},
  'robotCleanerJobMode': {'currentJobMode': 'ZIGZAG'},
};

// ------------------------------------------------------------ mock server --
/// Records requests and answers from a route table (`"GET /path"` ->
/// handler). Exact URL matching on `path?query`.
class Recorded {
  Recorded(this.request, this.body);
  final http.Request request;
  final String body;
  String get method => request.method;
  String get path => request.url.path;
  Map<String, String> get headers => request.headers;
  dynamic get json => body.isEmpty ? null : jsonDecode(body);
}

class MockCloud {
  final Map<String, http.Response Function(Recorded)> routes = {};
  final List<Recorded> calls = [];
  Object? transportError;

  void on(String method, String urlOrPath, Object json, {int status = 200}) {
    routes['$method $urlOrPath'] = (_) =>
        http.Response(jsonEncode(json), status, headers: {'content-type': 'application/json'});
  }

  void onFn(String method, String urlOrPath, http.Response Function(Recorded) fn) => routes['$method $urlOrPath'] = fn;

  List<Recorded> get posts => calls.where((c) => c.method == 'POST').toList();

  late final MockClient client = MockClient((req) async {
    final rec = Recorded(req, req.body);
    calls.add(rec);
    if (transportError != null) throw transportError!;
    final full = req.url.toString();
    final fn = routes['${req.method} $full'] ?? routes['${req.method} ${req.url.path}'];
    if (fn == null) return http.Response('{"error":"no route for ${req.method} $full"}', 404);
    return fn(rec);
  });
}
