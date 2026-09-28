import 'package:flutter_test/flutter_test.dart';
import 'package:homeiot/api/hub_api.dart';
import 'package:homeiot/models/hub_config.dart';
import 'package:homeiot/state/hub_state.dart';
import 'package:homeiot/state/settings_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_hub_api.dart';

void main() {
  late FakeHubApi api;
  late HubState hub;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    api = FakeHubApi();
    hub = HubState(settings: SettingsStore(await SharedPreferences.getInstance()), apiFactory: (_) => api);
  });

  test('connect loads catalog + devices and remembers the hub', () async {
    expect(await hub.connect(const HubConfig(host: '10.0.0.2', token: 'abc')), isTrue);
    expect(hub.status, HubStatus.connected);
    expect(hub.devices.length, 6);
    expect(hub.specs['power']!.uiHint, 'toggle');
    final saved = hub.settings.loadHub()!;
    expect((saved.host, saved.token, saved.name), ('10.0.0.2', 'abc', 'TestHub'));
  });

  test('connect failure reports an error', () async {
    api.healthy = false;
    expect(await hub.connect(const HubConfig(host: 'x')), isFalse);
    expect(hub.status, HubStatus.error);
  });

  test('websocket events update devices live', () async {
    await hub.connect(const HubConfig(host: 'h'));
    final lock = Map<String, dynamic>.from(api.deviceJson.firstWhere((d) => d['id'] == 'demo:lock'));
    lock['capabilities'] = {
      'lock': {
        'key': 'lock',
        'actions': ['lock', 'unlock'],
        'state': {'locked': false},
      },
    };
    api.events$.add(HubEvent('command', {'type': 'command', 'deviceId': 'demo:lock', 'device': lock}));
    await Future<void>.delayed(Duration.zero);
    expect(hub.liveConnected, isTrue);
    expect(hub.device('demo:lock')!.cap('lock')!.state['locked'], isFalse);
    api.events$.add(const HubEvent('devices', {'devices': []}));
    await Future<void>.delayed(Duration.zero);
    expect(hub.devices, isEmpty);
  });

  test('command errors propagate as HubApiException', () async {
    await hub.connect(const HubConfig(host: 'h'));
    api.failures['washer.start'] = const HubApiException(403, 'Remote Start off');
    expect(() => hub.command('demo:washer', 'washer', 'start'), throwsA(isA<HubApiException>()));
  });
}
