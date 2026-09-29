import 'package:flutter_test/flutter_test.dart';
import 'package:homeiot/backend/device_backend.dart';
import 'package:homeiot/backend/direct/cloud_provider.dart';
import 'package:homeiot/backend/direct/smartthings_client.dart';
import 'package:homeiot/models/device.dart';

import 'fixtures.dart';

void main() {
  late MockCloud cloud;
  late SmartThingsClient st;

  void registerAll({String washerRemote = 'true'}) {
    cloud.on('GET', '$stBase/devices', {
      'items': [stTv, stWasher, stDryer],
      '_links': {
        'next': {'href': '$stBase/devices?page=2'},
      },
    });
    cloud.on('GET', '$stBase/devices?page=2', {
      'items': [stFridge, stVacuum],
      '_links': {},
    });
    cloud.on('GET', '$stBase/devices/tv-1/status', stTvStatus);
    cloud.on('GET', '$stBase/devices/washer-1/status', stWasherStatus(remote: washerRemote));
    cloud.on('GET', '$stBase/devices/dryer-1/status', stDryerStatus);
    cloud.on('GET', '$stBase/devices/fridge-1/status', stFridgeStatus);
    cloud.on('GET', '$stBase/devices/vac-1/status', stVacuumStatus);
  }

  Future<Map<String, Device>> devices() async => {
    for (final d in await st.listDevices()) d.meta['cloudId'] as String: d,
  };

  Map<String, dynamic> lastCommand() => (cloud.posts.last.json['commands'] as List).first as Map<String, dynamic>;

  setUp(() {
    cloud = MockCloud();
    st = SmartThingsClient(token: () async => 'pat-123', client: cloud.client, now: () => DateTime.utc(2026, 9, 29));
  });

  test('no token configured -> 503, nothing sent', () async {
    final c = SmartThingsClient(token: () async => null, client: cloud.client);
    await expectLater(c.listDevices(), throwsA(isA<BackendException>().having((e) => e.statusCode, 'status', 503)));
    expect(cloud.calls, isEmpty);
  });

  test('list devices paginates, sends bearer, maps kinds', () async {
    registerAll();
    final devs = await devices();
    expect(devs.keys.toSet(), {'tv-1', 'washer-1', 'dryer-1', 'fridge-1', 'vac-1'});
    expect(cloud.calls.first.headers['Authorization'], 'Bearer pat-123');
    expect(
      {for (final e in devs.entries) e.key: e.value.kind},
      {'tv-1': 'tv', 'washer-1': 'washer', 'dryer-1': 'dryer', 'fridge-1': 'refrigerator', 'vac-1': 'vacuum'},
    );
    expect(devs.values.every((d) => d.id.startsWith('smartthings:') && d.adapter == 'smartthings'), isTrue);
    expect(cloud.calls.where((c) => c.request.url.toString() == '$stBase/devices?page=2'), hasLength(1));
  });

  test('TV status -> canonical power/volume/channel/mediaInput/playback', () async {
    registerAll();
    final tv = (await devices())['tv-1']!;
    expect(tv.cap('power')!.state, {'switch': 'on'});
    expect(tv.cap('volume')!.state, {'level': 12, 'muted': false});
    expect(tv.cap('volume')!.supports('setLevel'), isTrue);
    expect(tv.cap('channel')!.state['channel'], '11');
    expect(tv.cap('mediaInput')!.state, {
      'sources': ['digitalTv', 'HDMI1', 'HDMI2'],
      'selected': 'HDMI1',
    });
    expect(tv.cap('mediaPlayback')!.actions, ['play', 'pause', 'stop']);
    expect(tv.meta['match']['model'], 'UN55KS8500FXZA');
    expect(tv.reachable, isTrue);
    expect(tv.controllable, isTrue);
  });

  test('samsungvd.mediaInputSource takes precedence and is used for commands', () async {
    final item = {
      'deviceId': 'tv-2',
      'label': 'Frame',
      'components': [
        stComponent('main', ['switch', 'samsungvd.mediaInputSource', 'mediaInputSource'], ['Television']),
      ],
    };
    final status = {
      'main': {
        'samsungvd.mediaInputSource': {
          'supportedInputSourcesMap': stAttr([
            {'id': 'HDMI1', 'name': 'a'},
            {'id': 'dtv', 'name': 'b'},
          ]),
          'inputSource': stAttr('dtv'),
        },
      },
    };
    final d = st.deviceFromItem(item, status);
    expect(d.cap('mediaInput')!.strings('sources'), ['HDMI1', 'dtv']);
    cloud.on('POST', '$stBase/devices/tv-2/commands', {'results': []});
    await st.execute(d, 'mediaInput', 'select', {'source': 'HDMI1'});
    expect(lastCommand()['capability'], 'samsungvd.mediaInputSource');
  });

  group('TV command translation', () {
    for (final (cap, action, params, expected) in <(String, String, Map<String, dynamic>, List<Object?>)>[
      ('power', 'turnOff', {}, ['switch', 'off', []]),
      ('power', 'toggle', {}, ['switch', 'off', []]), // state is "on"
      (
        'volume',
        'setLevel',
        {'level': 30},
        [
          'audioVolume',
          'setVolume',
          [30],
        ],
      ),
      ('volume', 'volumeUp', {}, ['audioVolume', 'volumeUp', []]),
      ('volume', 'mute', {}, ['audioMute', 'mute', []]),
      (
        'channel',
        'setChannel',
        {'channel': 7},
        [
          'tvChannel',
          'setTvChannel',
          ['7'],
        ],
      ),
      ('channel', 'channelUp', {}, ['tvChannel', 'channelUp', []]),
      (
        'mediaInput',
        'select',
        {'source': 'HDMI2'},
        [
          'mediaInputSource',
          'setInputSource',
          ['HDMI2'],
        ],
      ),
      ('mediaPlayback', 'pause', {}, ['mediaPlayback', 'pause', []]),
    ]) {
      test('$cap.$action', () async {
        registerAll();
        cloud.on('POST', '$stBase/devices/tv-1/commands', {
          'results': [
            {'status': 'ACCEPTED'},
          ],
        });
        final tv = (await devices())['tv-1']!;
        final res = await st.execute(tv, cap, action, params);
        expect(res['ok'], isTrue);
        final c = lastCommand();
        expect([c['capability'], c['command'], c['arguments']], expected);
        expect(c['component'], 'main');
      });
    }
  });

  test('bad params and unknown actions are rejected before any request', () async {
    registerAll();
    final tv = (await devices())['tv-1']!;
    final before = cloud.calls.length;
    await expectLater(st.execute(tv, 'volume', 'setLevel', {'level': 101}), throwsA(isA<BackendException>()));
    await expectLater(st.execute(tv, 'volume', 'explode', {}), throwsA(isA<BackendException>()));
    await expectLater(st.execute(tv, 'nope', 'x', {}), throwsA(isA<BackendException>()));
    await expectLater(st.execute(tv, 'channel', 'setChannel', {'channel': ' '}), throwsA(isA<BackendException>()));
    expect(cloud.calls.length, before);
  });

  test('washer mapping and commands', () async {
    registerAll();
    final w = (await devices())['washer-1']!;
    final s = w.cap('washer')!.state;
    expect(s['machineState'], 'run');
    expect(s['jobState'], 'rinse');
    expect(s['remainingMinutes'], 42);
    expect(s['remoteControlEnabled'], isTrue);
    expect(w.cap('washer')!.actions, ['start', 'pause', 'stop']);

    cloud.on('POST', '$stBase/devices/washer-1/commands', {'results': []});
    await st.execute(w, 'washer', 'start', {});
    expect(lastCommand()['arguments'], ['run']);
    await st.execute(w, 'washer', 'pause', {});
    expect(
      [lastCommand()['capability'], lastCommand()['arguments']],
      [
        'washerOperatingState',
        ['pause'],
      ],
    );
  });

  test('washer start is refused when remote control was switched off since the last sync', () async {
    registerAll(); // sync saw remote enabled ...
    final w = (await devices())['washer-1']!;
    cloud.on('GET', '$stBase/devices/washer-1/status', stWasherStatus(remote: 'false')); // ... user turned it off
    cloud.on('POST', '$stBase/devices/washer-1/commands', {});
    await expectLater(
      st.execute(w, 'washer', 'start', {}),
      throwsA(
        isA<BackendException>()
            .having((e) => e.statusCode, 'status', 403)
            .having((e) => e.message, 'message', contains('원격 시작')),
      ),
    );
    expect(cloud.posts, isEmpty);
    // pause/stop are still forwarded (the vendor decides)
    await st.execute(w, 'washer', 'stop', {});
    expect(lastCommand()['arguments'], ['stop']);
  });

  test('dryer mapping: stop state, completion in the past, remote off refuses start', () async {
    registerAll();
    final d = (await devices())['dryer-1']!;
    expect(d.cap('dryer')!.state, {
      'machineState': 'stop',
      'jobState': 'none',
      'remainingMinutes': 0,
      'completionTime': '2020-01-01T00:00:00Z',
      'remoteControlEnabled': false,
    });
    await expectLater(
      st.execute(d, 'dryer', 'start', {}),
      throwsA(isA<BackendException>().having((e) => e.isForbidden, '403', true)),
    );
  });

  test('running laundry without samsungce remaining time derives minutes from completionTime', () {
    final item = {
      'deviceId': 'w2',
      'label': 'W2',
      'components': [
        stComponent('main', ['washerOperatingState'], ['Washer']),
      ],
    };
    final status = {
      'main': {
        'washerOperatingState': {
          'machineState': stAttr('run'),
          'completionTime': stAttr('2026-09-29T01:30:30Z'), // now = 2026-09-29T00:00Z
        },
      },
    };
    expect(st.deviceFromItem(item, status).cap('washer')!.state['remainingMinutes'], 91); // ceil(90.5)
    // a timestamp without zone is treated as UTC (like the hub)
    status['main']!['washerOperatingState']!['completionTime'] = stAttr('2026-09-29T00:10:00');
    expect(st.deviceFromItem(item, status).cap('washer')!.state['remainingMinutes'], 10);
  });

  test('fridge mapping and commands', () async {
    registerAll();
    final f = (await devices())['fridge-1']!;
    final inst = f.cap('refrigeration')!;
    expect(inst.state['fridgeTemperature'], 4);
    expect(inst.state['freezerSetpoint'], -19);
    expect(inst.state['unit'], 'C');
    expect(inst.state['doors'], {'main': false, 'cooler': true, 'freezer': false});
    expect(inst.state['doorOpen'], isTrue);
    expect(inst.state['rapidCooling'], isFalse);
    expect(inst.state['rapidFreezing'], isTrue);
    expect(inst.actions.toSet(), {'setFridgeSetpoint', 'setFreezerSetpoint', 'setRapidCooling', 'setRapidFreezing'});

    cloud.on('POST', '$stBase/devices/fridge-1/commands', {});
    await st.execute(f, 'refrigeration', 'setFreezerSetpoint', {'temperature': -20});
    var c = lastCommand();
    expect(
      [c['component'], c['capability'], c['command'], c['arguments']],
      [
        'freezer',
        'thermostatCoolingSetpoint',
        'setCoolingSetpoint',
        [-20],
      ],
    );
    await st.execute(f, 'refrigeration', 'setFridgeSetpoint', {'temperature': 3.0});
    c = lastCommand();
    expect(
      [c['component'], c['arguments']],
      [
        'cooler',
        [3],
      ],
    );
    await st.execute(f, 'refrigeration', 'setRapidCooling', {'enabled': true});
    c = lastCommand();
    expect(
      [c['capability'], c['command'], c['arguments']],
      [
        'refrigeration',
        'setRapidCooling',
        ['on'],
      ],
    );
    await expectLater(
      st.execute(f, 'refrigeration', 'setFridgeSetpoint', {'temperature': 'cold'}),
      throwsA(isA<BackendException>()),
    );
  });

  test('fridge without the refrigeration capability falls back to samsungce.powerCool/powerFreeze', () async {
    final item = {
      'deviceId': 'f2',
      'label': 'F2',
      'components': [
        stComponent('main', ['samsungce.powerCool', 'samsungce.powerFreeze'], ['Refrigerator']),
        stComponent('cooler', ['thermostatCoolingSetpoint']),
      ],
    };
    final status = {
      'main': {
        'samsungce.powerCool': {'activated': stAttr(true)},
      },
    };
    final f = st.deviceFromItem(item, status);
    expect(f.cap('refrigeration')!.state['rapidCooling'], isTrue);
    cloud.on('POST', '$stBase/devices/f2/commands', {});
    await st.execute(f, 'refrigeration', 'setRapidFreezing', {'enabled': false});
    expect([lastCommand()['capability'], lastCommand()['command']], ['samsungce.powerFreeze', 'deactivate']);
  });

  test('vacuum mapping and commands', () async {
    registerAll();
    final v = (await devices())['vac-1']!;
    final s = v.cap('vacuum')!.state;
    expect(s['status'], 'charging');
    expect(s['battery'], 87);
    expect(s['cleaningMode'], 'auto');
    expect(s['cleaningModes'], ['auto', 'part', 'repeat', 'manual', 'stop', 'map']);
    cloud.on('POST', '$stBase/devices/vac-1/commands', {});
    await st.execute(v, 'vacuum', 'start', {});
    expect(lastCommand()['arguments'], ['cleaning']);
    await st.execute(v, 'vacuum', 'dock', {});
    expect(lastCommand()['arguments'], ['homing']);
    await st.execute(v, 'vacuum', 'setCleaningMode', {'mode': 'repeat'});
    expect(
      [lastCommand()['capability'], lastCommand()['arguments']],
      [
        'robotCleanerCleaningMode',
        ['repeat'],
      ],
    );
    await st.execute(v, 'vacuum', 'stop', {});
    expect(lastCommand()['arguments'], ['stop']);
    await expectLater(st.execute(v, 'vacuum', 'setCleaningMode', {'mode': 'turbo'}), throwsA(isA<BackendException>()));
  });

  test('offline device is still listed, marked unreachable', () async {
    registerAll();
    final tv = Map<String, dynamic>.from(stTv)..['healthState'] = {'state': 'OFFLINE'};
    cloud.on('GET', '$stBase/devices', {
      'items': [tv],
    });
    cloud.on('GET', '$stBase/devices/tv-1/status', {'error': 'gone'}, status: 500);
    final list = await st.listDevices();
    expect(list.single.reachable, isFalse);
    expect(list.single.cap('power')!.state['switch'], 'unknown');
  });

  test('401 -> CloudAuthException that explains the 24 h PAT expiry', () async {
    cloud.on('GET', '$stBase/devices', {'error': 'invalid_token'}, status: 401);
    await expectLater(
      st.listDevices(),
      throwsA(
        isA<CloudAuthException>()
            .having((e) => e.statusCode, 'status', 401)
            .having((e) => e.providerId, 'provider', 'smartthings')
            .having((e) => e.message, 'message', allOf(contains('24시간'), contains('토큰'))),
      ),
    );
  });

  test('403 is also treated as a rejected token', () async {
    cloud.on('GET', '$stBase/devices', {'error': 'forbidden'}, status: 403);
    await expectLater(st.listDevices(), throwsA(isA<CloudAuthException>()));
  });

  test('other HTTP errors -> 502, 429 -> rate-limit message, network failure -> 0', () async {
    cloud.on('GET', '$stBase/devices', {'error': 'boom'}, status: 500);
    await expectLater(st.listDevices(), throwsA(isA<BackendException>().having((e) => e.statusCode, 's', 502)));
    cloud.on('GET', '$stBase/devices', {}, status: 429);
    await expectLater(st.listDevices(), throwsA(isA<BackendException>().having((e) => e.statusCode, 's', 429)));
    cloud.transportError = Exception('offline');
    await expectLater(st.listDevices(), throwsA(isA<BackendException>().having((e) => e.statusCode, 's', 0)));
  });

  test('refresh re-reads status and updates state only', () async {
    registerAll();
    final w = (await devices())['washer-1']!;
    cloud.on('GET', '$stBase/devices/washer-1/status', stWasherStatus(machine: 'pause'));
    final fresh = await st.refresh(w);
    expect(fresh.cap('washer')!.state['machineState'], 'pause');
    expect(fresh.cap('washer')!.actions, w.cap('washer')!.actions);
    expect(fresh.reachable, isTrue);
    expect(w.cap('washer')!.state['machineState'], 'run'); // original untouched
  });

  test('token is read for every request (rotated token is picked up)', () async {
    var tok = 'old';
    final c = SmartThingsClient(token: () async => tok, client: cloud.client);
    cloud.on('GET', '$stBase/devices', {'items': []});
    await c.listDevices();
    tok = 'new';
    await c.listDevices();
    expect(cloud.calls.map((r) => r.headers['Authorization']), ['Bearer old', 'Bearer new']);
  });

  group('curtain / blind + light (same mapping as the Python hub)', () {
    void registerHome() {
      cloud.on('GET', '$stBase/devices', {
        'items': [stCurtain, stLevelOnly, stLight, stLegacyLight],
      });
      cloud.on('GET', '$stBase/devices/cur-1/status', stCurtainStatus(shade: 'partially open', level: 40));
      cloud.on('GET', '$stBase/devices/cur-2/status', {
        'components': {
          'main': {
            'windowShadeLevel': {'shadeLevel': stAttr(0)},
          },
        },
      });
      cloud.on('GET', '$stBase/devices/light-1/status', {
        'components': {
          'main': {
            'switch': {'switch': stAttr('on')},
            'switchLevel': {'level': stAttr(80)},
          },
        },
      });
      cloud.on('GET', '$stBase/devices/light-2/status', {
        'components': {
          'main': {
            'light': {'switch': stAttr('off')},
          },
        },
      });
      for (final id in ['cur-1', 'cur-2', 'light-1', 'light-2']) {
        cloud.on('POST', '$stBase/devices/$id/commands', {'results': []});
      }
    }

    test('windowShade maps to the canonical curtain capability (kind from category)', () async {
      registerHome();
      final devs = await devices();
      final c = devs['cur-1']!;
      expect(c.kind, 'curtain');
      final inst = c.cap('curtain')!;
      expect(inst.actions.toSet(), {'open', 'close', 'stop', 'setPosition'});
      expect(inst.state['position'], 40);
      expect(inst.state['status'], 'partial');
      final lvl = devs['cur-2']!;
      expect(lvl.kind, 'curtain');
      expect(lvl.cap('curtain')!.state['status'], 'closed');
    });

    test('commands: open/close/stop/setPosition, validation, level-only emulation', () async {
      registerHome();
      final devs = await devices();
      final c = devs['cur-1']!;
      for (final (action, params, cap, cmd, args) in [
        ('open', <String, dynamic>{}, 'windowShade', 'open', <Object>[]),
        ('close', <String, dynamic>{}, 'windowShade', 'close', <Object>[]),
        ('stop', <String, dynamic>{}, 'windowShade', 'pause', <Object>[]),
        ('setPosition', <String, dynamic>{'position': 25}, 'windowShadeLevel', 'setShadeLevel', <Object>[25]),
      ]) {
        await st.execute(c, 'curtain', action, params);
        final sent = lastCommand();
        expect([sent['capability'], sent['command'], sent['arguments']], [cap, cmd, args], reason: action);
      }
      for (final bad in [
        {'position': 101},
        {'position': -1},
        <String, dynamic>{},
        {'position': 'x'},
      ]) {
        await expectLater(st.execute(c, 'curtain', 'setPosition', bad), throwsA(isA<BackendException>()));
      }
      final lvl = devs['cur-2']!;
      await st.execute(lvl, 'curtain', 'open', {});
      expect(
        [lastCommand()['capability'], lastCommand()['command'], lastCommand()['arguments']],
        [
          'windowShadeLevel',
          'setShadeLevel',
          [100],
        ],
      );
      await st.execute(lvl, 'curtain', 'close', {});
      expect(lastCommand()['arguments'], [0]);
    });

    test('a shade that cannot pause does not offer stop', () async {
      cloud.on('GET', '$stBase/devices', {
        'items': [stCurtain],
      });
      cloud.on(
        'GET',
        '$stBase/devices/cur-1/status',
        stCurtainStatus(shade: 'closed', level: 0, supported: ['open', 'close']),
      );
      expect((await devices())['cur-1']!.cap('curtain')!.actions, isNot(contains('stop')));
    });

    test('switch and legacy light both become power; legacy keeps its own capability name on the wire', () async {
      registerHome();
      final devs = await devices();
      expect(devs['light-1']!.kind, 'light');
      expect(devs['light-1']!.powerOn, isTrue);
      expect(devs['light-1']!.has('brightness'), isTrue);
      expect(devs['light-2']!.powerOn, isFalse);
      await st.execute(devs['light-2']!, 'power', 'turnOn', {});
      expect([lastCommand()['capability'], lastCommand()['command']], ['light', 'on']);
      await st.execute(devs['light-1']!, 'power', 'turnOff', {});
      expect([lastCommand()['capability'], lastCommand()['command']], ['switch', 'off']);
    });
  });
}
