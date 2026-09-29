import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:homeiot/backend/device_backend.dart';
import 'package:homeiot/backend/direct/cloud_provider.dart';
import 'package:homeiot/backend/direct/lg_thinq_client.dart';
import 'package:homeiot/models/device.dart';

import 'fixtures.dart';

void main() {
  late MockCloud cloud;
  late LgThinqClient lg;

  void register({bool washerRemote = true}) {
    cloud.on('GET', '$lgBase/devices', lgEnv(lgDevices));
    cloud.on('GET', '$lgBase/devices/lg-washer/profile', lgEnv(lgLaundryProfile('washerOperationMode')));
    cloud.on('GET', '$lgBase/devices/lg-washer/state', lgEnv(lgLaundryState(remote: washerRemote)));
    cloud.on('GET', '$lgBase/devices/lg-dryer/profile', lgEnv(lgLaundryProfile('dryerOperationMode')));
    cloud.on('GET', '$lgBase/devices/lg-dryer/state', lgEnv(lgLaundryState(current: 'PAUSE', remote: false)));
    cloud.on('GET', '$lgBase/devices/lg-fridge/profile', lgEnv(lgFridgeProfile));
    cloud.on('GET', '$lgBase/devices/lg-fridge/state', lgEnv(lgFridgeState));
    cloud.on('GET', '$lgBase/devices/lg-robot/profile', lgEnv(lgRobotProfile));
    cloud.on('GET', '$lgBase/devices/lg-robot/state', lgEnv(lgRobotState()));
  }

  Future<Map<String, Device>> devices() async => {
    for (final d in await lg.listDevices()) d.meta['cloudId'] as String: d,
  };

  Map<String, dynamic> lastBody() => cloud.posts.last.json as Map<String, dynamic>;

  setUp(() {
    cloud = MockCloud();
    lg = LgThinqClient(
      token: () async => 'lg-pat',
      country: 'KR',
      clientId: 'homeiot-test-client',
      client: cloud.client,
      random: Random(1),
    );
  });

  test('region mapping and default country', () {
    expect(LgThinqClient.regionForCountry('KR'), 'kic');
    expect(LgThinqClient.regionForCountry('us'), 'aic');
    expect(LgThinqClient.regionForCountry('DE'), 'eic');
    expect(lg.baseUrl, 'https://api-kic.lgthinq.com');
    final us = LgThinqClient(token: () async => 't', country: 'us', clientId: 'c');
    expect(us.baseUrl, 'https://api-aic.lgthinq.com');
    final blank = LgThinqClient(token: () async => 't', country: ' ', clientId: 'c');
    expect(blank.baseUrl, 'https://api-kic.lgthinq.com');
  });

  test('no token configured -> 503, nothing sent', () async {
    final c = LgThinqClient(token: () async => '', country: 'KR', clientId: 'x', client: cloud.client);
    await expectLater(c.listDevices(), throwsA(isA<BackendException>().having((e) => e.statusCode, 's', 503)));
    expect(cloud.calls, isEmpty);
  });

  test('list devices: headers, kinds, unmapped types are passive', () async {
    register();
    final devs = await devices();
    expect(
      {for (final e in devs.entries) e.key: e.value.kind},
      {
        'lg-washer': 'washer',
        'lg-dryer': 'dryer',
        'lg-fridge': 'refrigerator',
        'lg-robot': 'vacuum',
        'lg-styler': 'styler',
      },
    );
    expect(devs['lg-styler']!.controllable, isFalse);
    expect(devs.values.every((d) => d.id.startsWith('lg_thinq:') && d.adapter == 'lg_thinq'), isTrue);
    final h = cloud.calls.first.headers;
    expect(h['Authorization'], 'Bearer lg-pat');
    expect(h['x-country'], 'KR');
    expect(h['x-client-id'], 'homeiot-test-client');
    expect(h['x-api-key'], LgThinqClient.defaultApiKey);
    expect(h['x-service-phase'], 'OP');
    expect(h['x-message-id'], hasLength(22));
    expect(h['x-message-id'], matches(RegExp(r'^[A-Za-z0-9_-]{22}$')));
    expect(cloud.calls[1].headers['x-message-id'], isNot(h['x-message-id']));
    expect(h.containsKey('x-conditional-control'), isFalse);
  });

  test('washer mapping and control', () async {
    register();
    final w = (await devices())['lg-washer']!;
    final inst = w.cap('washer')!;
    expect(inst.state, {
      'machineState': 'run',
      'jobState': 'running',
      'remainingMinutes': 65,
      'completionTime': null,
      'remoteControlEnabled': true,
    });
    expect(inst.actions, ['start', 'pause', 'stop']);
    expect(w.meta['location'], 'MAIN');

    cloud.on('POST', '$lgBase/devices/lg-washer/control', lgEnv({}));
    await lg.execute(w, 'washer', 'start', {});
    expect(lastBody(), {
      'location': {'locationName': 'MAIN'},
      'operation': {'washerOperationMode': 'START'},
    });
    expect(cloud.posts.last.headers['x-conditional-control'], 'true');
    await lg.execute(w, 'washer', 'pause', {});
    expect(lastBody()['operation'], {'washerOperationMode': 'STOP'});
    await lg.execute(w, 'washer', 'stop', {});
    expect(lastBody()['operation'], {'washerOperationMode': 'POWER_OFF'});
  });

  test('washer start refused (no POST) when the live state says remote control is off', () async {
    register(washerRemote: false);
    final w = (await devices())['lg-washer']!;
    cloud.on('POST', '$lgBase/devices/lg-washer/control', lgEnv({}));
    await expectLater(
      lg.execute(w, 'washer', 'start', {}),
      throwsA(
        isA<BackendException>()
            .having((e) => e.statusCode, 'status', 403)
            .having((e) => e.message, 'message', contains('원격 시작')),
      ),
    );
    expect(cloud.posts, isEmpty);
  });

  test('live re-read catches a flag that changed after the last sync', () async {
    register(); // enabled at sync time
    final w = (await devices())['lg-washer']!;
    cloud.on('GET', '$lgBase/devices/lg-washer/state', lgEnv(lgLaundryState(remote: false)));
    cloud.on('POST', '$lgBase/devices/lg-washer/control', lgEnv({}));
    await expectLater(
      lg.execute(w, 'washer', 'start', {}),
      throwsA(isA<BackendException>().having((e) => e.isForbidden, '403', true)),
    );
    expect(cloud.posts, isEmpty);
  });

  test('vendor error 2301 (remote off) maps to a refusal even for stop', () async {
    register();
    final w = (await devices())['lg-washer']!;
    cloud.on('POST', '$lgBase/devices/lg-washer/control', {
      'error': {'code': '2301', 'message': 'Command not supported in remote off'},
    }, status: 400);
    await expectLater(
      lg.execute(w, 'washer', 'stop', {}),
      throwsA(
        isA<BackendException>().having((e) => e.statusCode, 's', 403).having((e) => e.message, 'm', contains('2301')),
      ),
    );
  });

  test('dryer mapping (paused, remote off) and control', () async {
    register();
    final d = (await devices())['lg-dryer']!;
    expect(d.cap('dryer')!.state['machineState'], 'pause');
    expect(d.cap('dryer')!.state['remoteControlEnabled'], isFalse);
    await expectLater(
      lg.execute(d, 'dryer', 'start', {}),
      throwsA(isA<BackendException>().having((e) => e.isForbidden, '403', true)),
    );
    cloud.on('POST', '$lgBase/devices/lg-dryer/control', lgEnv({}));
    await lg.execute(d, 'dryer', 'stop', {});
    expect(lastBody()['operation'], {'dryerOperationMode': 'POWER_OFF'});
  });

  test('washer tower: one device per location', () {
    final item = lgDevices.first;
    final profile = {
      'property': [
        for (final loc in ['MAIN', 'MINI'])
          {
            'location': {'locationName': loc},
            'operation': {
              'washerOperationMode': {
                'mode': ['w'],
                'value': {
                  'w': ['START'],
                },
              },
            },
          },
      ],
    };
    final state = [
      {
        'location': {'locationName': 'MAIN'},
        'runState': {'currentState': 'RUNNING'},
      },
      {
        'location': {'locationName': 'MINI'},
        'runState': {'currentState': 'END'},
      },
    ];
    final devs = lg.devicesFromItem(item, profile, state);
    expect(devs.map((d) => d.id), ['lg_thinq:lg-washer:MAIN', 'lg_thinq:lg-washer:MINI']);
    expect(devs.map((d) => d.name), ['LG Washer (MAIN)', 'LG Washer (MINI)']);
    expect(devs[0].cap('washer')!.state['machineState'], 'run');
    expect(devs[1].cap('washer')!.state['machineState'], 'stop');
    expect(devs[0].cap('washer')!.actions, ['start']); // only writable values are offered
  });

  test('fridge mapping and control (setpoints only, no measured temperature)', () async {
    register();
    final f = (await devices())['lg-fridge']!;
    final inst = f.cap('refrigeration')!;
    expect(inst.state['fridgeSetpoint'], 3);
    expect(inst.state['freezerSetpoint'], -20);
    expect(inst.state['fridgeTemperature'], isNull);
    expect(inst.state['doorOpen'], isTrue);
    expect(inst.state['doors'], {'main': true});
    expect(inst.state['rapidCooling'], isTrue);
    expect(inst.state['rapidFreezing'], isFalse);
    expect(inst.state['unit'], 'C');
    expect(inst.actions.toSet(), {'setFridgeSetpoint', 'setFreezerSetpoint', 'setRapidCooling', 'setRapidFreezing'});

    cloud.on('POST', '$lgBase/devices/lg-fridge/control', lgEnv({}));
    await lg.execute(f, 'refrigeration', 'setFridgeSetpoint', {'temperature': 4});
    expect(lastBody(), {
      'temperatureInUnits': {'locationName': 'FRIDGE', 'targetTemperatureC': 4},
    });
    await lg.execute(f, 'refrigeration', 'setFreezerSetpoint', {'temperature': -18.0});
    expect(lastBody(), {
      'temperatureInUnits': {'locationName': 'FREEZER', 'targetTemperatureC': -18},
    });
    await lg.execute(f, 'refrigeration', 'setRapidFreezing', {'enabled': true});
    expect(lastBody(), {
      'refrigeration': {'rapidFreeze': true},
    });
    await lg.execute(f, 'refrigeration', 'setRapidCooling', {'enabled': false});
    expect(lastBody(), {
      'refrigeration': {'expressFridge': false},
    });
    await expectLater(
      lg.execute(f, 'refrigeration', 'setRapidCooling', {'enabled': 'yes'}),
      throwsA(isA<BackendException>()),
    );
    await expectLater(
      lg.execute(f, 'refrigeration', 'setFridgeSetpoint', {'temperature': 'x'}),
      throwsA(isA<BackendException>()),
    );
  });

  test('robot mapping and control (paused -> RESUME, sleeping -> WAKE_UP)', () async {
    register();
    final r = (await devices())['lg-robot']!;
    final inst = r.cap('vacuum')!;
    expect(inst.state['status'], 'paused');
    expect(inst.state['battery'], 76);
    expect(inst.state['cleaningMode'], 'ZIGZAG');
    expect(inst.state['cleaningModes'], ['ZIGZAG', 'SECTOR_BASE']);
    expect(inst.actions, ['start', 'pause', 'dock']);
    cloud.on('POST', '$lgBase/devices/lg-robot/control', lgEnv({}));
    await lg.execute(r, 'vacuum', 'start', {}); // paused -> RESUME
    expect(lastBody(), {
      'operation': {'cleanOperationMode': 'RESUME'},
    });
    await lg.execute(r, 'vacuum', 'dock', {});
    expect(lastBody()['operation'], {'cleanOperationMode': 'HOMING'});
    await lg.execute(r, 'vacuum', 'pause', {});
    expect(lastBody()['operation'], {'cleanOperationMode': 'PAUSE'});
    await expectLater(lg.execute(r, 'vacuum', 'stop', {}), throwsA(isA<BackendException>())); // not supported by LG

    final sleeping = lg.devicesFromItem(lgDevices[3], lgRobotProfile, lgRobotState(current: 'SLEEP')).single;
    await lg.execute(sleeping, 'vacuum', 'start', {});
    expect(lastBody()['operation'], {'cleanOperationMode': 'WAKE_UP'});

    final idle = lg.devicesFromItem(lgDevices[3], lgRobotProfile, lgRobotState(current: 'CHARGING')).single;
    await lg.execute(idle, 'vacuum', 'start', {});
    expect(lastBody()['operation'], {'cleanOperationMode': 'START'});
  });

  test('missing profile -> all laundry actions offered (device decides)', () {
    final d = lg.devicesFromItem(lgDevices[0], {}, lgLaundryState()).single;
    expect(d.cap('washer')!.actions, ['start', 'pause', 'stop']);
  });

  test('invalid token (401 / code 1103) -> CloudAuthException', () async {
    cloud.on('GET', '$lgBase/devices', {
      'error': {'code': '1103', 'message': 'Invalid token'},
    }, status: 401);
    await expectLater(
      lg.listDevices(),
      throwsA(
        isA<CloudAuthException>()
            .having((e) => e.providerId, 'provider', 'lg_thinq')
            .having((e) => e.statusCode, 's', 401),
      ),
    );
    cloud.on('GET', '$lgBase/devices', {
      'error': {'code': '1218', 'message': 'expired'},
    }, status: 400);
    await expectLater(lg.listDevices(), throwsA(isA<CloudAuthException>()));
  });

  test('a broken profile/state call does not hide the device, but auth errors propagate', () async {
    register();
    cloud.on('GET', '$lgBase/devices/lg-robot/state', {}, status: 500);
    final devs = await devices();
    expect(devs['lg-robot']!.cap('vacuum'), isNotNull);
    cloud.on('GET', '$lgBase/devices/lg-robot/state', {
      'error': {'code': '1103'},
    }, status: 401);
    await expectLater(lg.listDevices(), throwsA(isA<CloudAuthException>()));
  });

  test('refresh re-reads profile + state', () async {
    register();
    final r = (await devices())['lg-robot']!;
    cloud.on('GET', '$lgBase/devices/lg-robot/state', lgEnv(lgRobotState(current: 'CLEANING')));
    final fresh = await lg.refresh(r);
    expect(fresh.cap('vacuum')!.state['status'], 'cleaning');
    expect(fresh.meta['lgRunState'], 'CLEANING');
    expect(r.cap('vacuum')!.state['status'], 'paused');
  });

  test('network failure -> status 0', () async {
    cloud.transportError = Exception('no route');
    await expectLater(lg.listDevices(), throwsA(isA<BackendException>().having((e) => e.statusCode, 's', 0)));
  });
}
