import 'package:flutter_test/flutter_test.dart';
import 'package:homeiot/backend/device_backend.dart';
import 'package:homeiot/backend/direct/cloud_provider.dart';
import 'package:homeiot/backend/direct/direct_cloud_backend.dart';
import 'package:homeiot/backend/direct/direct_factory.dart';
import 'package:homeiot/backend/direct/lg_thinq_client.dart';
import 'package:homeiot/backend/direct/smartthings_client.dart';
import 'package:homeiot/models/capability_spec.dart';
import 'package:homeiot/models/hub_config.dart';
import 'package:homeiot/models/canonical_catalog.dart';
import 'package:homeiot/models/device.dart';
import 'package:homeiot/state/credentials_store.dart';
import 'package:homeiot/state/hub_state.dart';
import 'package:homeiot/state/settings_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fake_hub_api.dart';
import 'fixtures.dart';

/// Scriptable provider for backend-level tests.
class FakeProvider implements CloudProvider {
  FakeProvider(this.id, this.devices);
  @override
  final String id;
  @override
  String get name => '$id (cloud)';
  List<Device> devices;
  BackendException? failure;
  final List<String> executed = [];
  int refreshes = 0;

  @override
  Future<List<Device>> listDevices() async {
    if (failure != null) throw failure!;
    return devices;
  }

  @override
  Future<Device> refresh(Device d) async {
    refreshes++;
    return d.copyWith(reachable: true);
  }

  @override
  Future<Map<String, dynamic>> execute(Device d, String cap, String action, Map<String, dynamic> p) async {
    executed.add('${d.id} $cap.$action $p');
    return {'ok': true};
  }

  @override
  void close() {}
}

Device dev(String provider, String id, {String kind = 'light'}) => Device(
  id: '$provider:$id',
  name: id,
  adapter: provider,
  kind: kind,
  controllable: true,
  capabilities: {
    'power': const CapabilityInstance(key: 'power', actions: ['turnOn', 'turnOff']),
  },
);

void main() {
  group('DirectCloudBackend', () {
    test('merges providers, routes commands by provider, serves the canonical catalog', () async {
      final a = FakeProvider('smartthings', [dev('smartthings', 'a')]);
      final b = FakeProvider('lg_thinq', [dev('lg_thinq', 'b')]);
      final be = DirectCloudBackend(providers: [a, b], settleDelay: Duration.zero);
      expect((await be.sync()).map((d) => d.id).toSet(), {'smartthings:a', 'lg_thinq:b'});
      expect((await be.capabilities()).keys, containsAll(['power', 'washer', 'refrigeration', 'vacuum']));
      expect(be.kind, BackendKind.directCloud);
      expect(be.hasEventStream, isFalse);

      await be.command('lg_thinq:b', 'power', 'turnOn');
      expect(b.executed, ['lg_thinq:b power.turnOn {}']);
      expect(a.executed, isEmpty);
      expect(b.refreshes, 1); // state re-read after the command
    });

    test('rejects commands for unknown devices / capabilities the device lacks', () async {
      final be = DirectCloudBackend(
        providers: [
          FakeProvider('p', [dev('p', 'a')]),
        ],
        settleDelay: Duration.zero,
      );
      await be.sync();
      await expectLater(
        be.command('p:zzz', 'power', 'turnOn'),
        throwsA(isA<BackendException>().having((e) => e.statusCode, 's', 404)),
      );
      await expectLater(
        be.command('p:a', 'lock', 'lock'),
        throwsA(isA<BackendException>().having((e) => e.statusCode, 's', 400)),
      );
    });

    test('one provider failing becomes a warning; the other keeps working', () async {
      final a = FakeProvider('smartthings', [dev('smartthings', 'a')]);
      final b = FakeProvider('lg_thinq', [dev('lg_thinq', 'b')]);
      final be = DirectCloudBackend(providers: [a, b]);
      await be.sync();
      a.failure = const CloudAuthException('smartthings', 'expired');
      final list = await be.sync();
      expect(list.map((d) => d.id), ['lg_thinq:b']); // auth failure: stale devices are dropped
      expect(be.warnings, {'smartthings': 'expired'});
      a.failure = null;
      await be.sync();
      expect(be.warnings, isEmpty);
    });

    test('transient (non-auth) failure keeps the last known devices', () async {
      final a = FakeProvider('smartthings', [dev('smartthings', 'a')]);
      final b = FakeProvider('lg_thinq', [dev('lg_thinq', 'b')]);
      final be = DirectCloudBackend(providers: [a, b]);
      await be.sync();
      b.failure = const BackendException(0, 'offline');
      expect((await be.sync()).map((d) => d.id).toSet(), {'smartthings:a', 'lg_thinq:b'});
      expect(be.warnings.keys, ['lg_thinq']);
    });

    test('all providers failing throws the first error and records warnings', () async {
      final a = FakeProvider('smartthings', [])..failure = const CloudAuthException('smartthings', 'expired');
      final be = DirectCloudBackend(providers: [a]);
      await expectLater(be.sync(), throwsA(isA<CloudAuthException>()));
      expect(be.warnings['smartthings'], 'expired');
    });

    test('vacuum map is not available in direct mode (501)', () async {
      final be = DirectCloudBackend(providers: []);
      await expectLater(be.vacuumMap('x'), throwsA(isA<BackendException>().having((e) => e.statusCode, 's', 501)));
    });
  });

  test('bundled canonical catalog matches the hub capability catalog fixture', () {
    final hub = CapabilitySpec.parseCatalog(fixture('capabilities'));
    // The demo fixture may predate newer capabilities; every hub entry must match exactly.
    for (final e in hub.entries) {
      final mine = canonicalCatalog[e.key];
      expect(mine, isNotNull, reason: 'missing ${e.key}');
      expect(mine!.uiHint, e.value.uiHint, reason: e.key);
      expect(mine.actions, e.value.actions, reason: e.key);
      expect(mine.state, e.value.state, reason: e.key);
    }
    expect(canonicalCatalog.length, greaterThanOrEqualTo(hub.length));
  });

  group('CredentialsStore', () {
    test('round trip, trimming, defaults', () async {
      final mem = MemorySecretStore();
      var clock = DateTime.utc(2026, 9, 29, 0);
      final s = CredentialsStore(mem, now: () => clock);
      expect((await s.load()).hasAny, isFalse);
      expect((await s.load()).lgCountry, 'KR');

      await s.saveSmartThings('  pat-1  ');
      await s.saveLg(' lg-1 ', 'us');
      final c = await s.load();
      expect((c.smartThingsToken, c.lgToken, c.lgCountry), ('pat-1', 'lg-1', 'US'));
      expect(c.smartThingsSavedAt, clock);
      expect(await s.smartThingsToken(), 'pat-1');

      await s.clearSmartThings();
      expect((await s.load()).hasSmartThings, isFalse);
      expect((await s.load()).smartThingsSavedAt, isNull);
      expect((await s.load()).hasLg, isTrue);
      await s.clearAll();
      expect((await s.load()).hasAny, isFalse);
    });

    test('SmartThings expiry hint after 24 h', () async {
      var clock = DateTime.utc(2026, 9, 29, 0);
      final s = CredentialsStore(MemorySecretStore(), now: () => clock);
      await s.saveSmartThings('pat');
      final c = await s.load();
      expect(c.smartThingsLikelyExpired(clock.add(const Duration(hours: 23, minutes: 59))), isFalse);
      expect(c.smartThingsLikelyExpired(clock.add(const Duration(hours: 24))), isTrue);
      expect(const CloudCredentials().smartThingsLikelyExpired(clock), isFalse);
    });

    test('LG client id is generated once and stable', () async {
      final mem = MemorySecretStore();
      final a = await CredentialsStore(mem).lgClientId();
      final b = await CredentialsStore(mem).lgClientId();
      expect(a, startsWith('homeiot-'));
      expect(a, b);
    });

    test('tokens live only in the injected secret store, not in SharedPreferences', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final mem = MemorySecretStore();
      await CredentialsStore(mem).saveSmartThings('super-secret');
      expect(prefs.getKeys(), isEmpty);
      expect(mem.data.values, contains('super-secret'));
    });
  });

  group('HubState in direct mode', () {
    late MockCloud cloud;
    late MemorySecretStore mem;
    late HubState state;
    late SettingsStore settings;
    var clock = DateTime.utc(2026, 9, 29, 0);

    void registerSt({bool ok = true}) {
      if (!ok) {
        cloud.on('GET', '$stBase/devices', {'error': 'invalid_token'}, status: 401);
        return;
      }
      cloud.on('GET', '$stBase/devices', {
        'items': [stTv, stWasher],
      });
      cloud.on('GET', '$stBase/devices/tv-1/status', stTvStatus);
      cloud.on('GET', '$stBase/devices/washer-1/status', stWasherStatus());
    }

    void registerLg() {
      cloud.on('GET', '$lgBase/devices', lgEnv(lgDevices.sublist(3, 4)));
      cloud.on('GET', '$lgBase/devices/lg-robot/profile', lgEnv(lgRobotProfile));
      cloud.on('GET', '$lgBase/devices/lg-robot/state', lgEnv(lgRobotState()));
    }

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      cloud = MockCloud();
      mem = MemorySecretStore();
      clock = DateTime.utc(2026, 9, 29, 0);
      settings = SettingsStore(await SharedPreferences.getInstance());
      state = HubState(
        settings: settings,
        apiFactory: (_) => FakeHubApi(),
        credentials: CredentialsStore(mem, now: () => clock),
        now: () => clock,
        directFactory: (store) async {
          final c = await store.load();
          return DirectCloudBackend(
            settleDelay: Duration.zero,
            pollInterval: null,
            providers: [
              if (c.hasSmartThings) SmartThingsClient(token: store.smartThingsToken, client: cloud.client),
              if (c.hasLg)
                LgThinqClient(token: store.lgToken, country: c.lgCountry, clientId: 'cid', client: cloud.client),
            ],
          );
        },
      );
    });

    test('new install defaults to direct mode and needs no hub', () {
      expect(settings.mode, BackendKind.directCloud);
      expect(state.status, HubStatus.disconnected);
    });

    test('an install that already remembers a hub keeps hub mode', () async {
      SharedPreferences.setMockInitialValues({'lastHub': '{"host":"10.0.0.2","port":8099}'});
      final s = SettingsStore(await SharedPreferences.getInstance());
      expect(s.mode, BackendKind.hub);
    });

    test('saveTokens stores in the secret store, loads devices from both clouds, and flips to direct mode', () async {
      registerSt();
      registerLg();
      final ok = await state.saveTokens(smartThings: 'pat-1', lgToken: 'lg-1', lgCountry: 'kr');
      expect(ok, isTrue);
      expect(state.status, HubStatus.connected);
      expect(state.mode, BackendKind.directCloud);
      expect(state.devices.map((d) => d.adapter).toSet(), {'smartthings', 'lg_thinq'});
      expect(state.devices, hasLength(3));
      expect(state.specs['washer']!.uiHint, 'laundry-cycle');
      expect(mem.data[CredentialsStore.kSmartThings], 'pat-1');
      expect(state.api, isNull); // no hub in this mode
      expect(state.backend!.title, '직접 연결');
      expect(state.warnings, isEmpty);
    });

    test('no tokens -> stays disconnected (onboarding is shown)', () async {
      expect(await state.saveTokens(), isFalse);
      expect(state.status, HubStatus.disconnected);
    });

    test('expired SmartThings PAT: app stays usable, error is surfaced, fixing the token recovers', () async {
      registerSt(ok: false);
      await state.saveTokens(smartThings: 'expired-pat');
      expect(state.status, HubStatus.connected);
      expect(state.devices, isEmpty);
      expect(state.error, contains('24시간'));
      expect(state.warnings['smartthings'], contains('24시간'));

      registerSt();
      await state.saveTokens(smartThings: 'fresh-pat');
      expect(state.error, isNull);
      expect(state.warnings, isEmpty);
      expect(state.devices, hasLength(2));
      expect(cloud.calls.last.headers['Authorization'], 'Bearer fresh-pat');
    });

    test('warns when the stored SmartThings token is older than 24 h even before any request fails', () async {
      registerSt();
      await state.saveTokens(smartThings: 'pat');
      expect(state.smartThingsLikelyExpired, isFalse);
      clock = clock.add(const Duration(hours: 25));
      expect(state.smartThingsLikelyExpired, isTrue);
    });

    test('command goes through the cloud client and refreshes; washer remote-off is a 403', () async {
      registerSt();
      await state.saveTokens(smartThings: 'pat');
      cloud.on('POST', '$stBase/devices/tv-1/commands', {'results': []});
      await state.command('smartthings:tv-1', 'volume', 'volumeUp');
      expect(cloud.posts.single.json['commands'][0]['command'], 'volumeUp');

      cloud.on('GET', '$stBase/devices/washer-1/status', stWasherStatus(remote: 'false'));
      await expectLater(
        state.command('smartthings:washer-1', 'washer', 'start'),
        throwsA(isA<BackendException>().having((e) => e.statusCode, 's', 403)),
      );
      expect(cloud.posts, hasLength(1)); // nothing sent for the refused start
    });

    test('reload/scan re-sync from the clouds', () async {
      registerSt();
      await state.saveTokens(smartThings: 'pat');
      cloud.on('GET', '$stBase/devices', {
        'items': [stTv],
      });
      await state.reload();
      expect(state.devices, hasLength(1));
      cloud.on('GET', '$stBase/devices', {
        'items': [stTv, stWasher],
      });
      await state.scan();
      expect(state.devices, hasLength(2));
    });

    test('start() resumes direct mode from stored tokens', () async {
      registerSt();
      await CredentialsStore(mem).saveSmartThings('pat');
      await state.start();
      expect(state.status, HubStatus.connected);
      expect(state.devices, hasLength(2));
    });

    test('removing every token returns to onboarding', () async {
      registerSt();
      await state.saveTokens(smartThings: 'pat');
      await state.saveTokens(smartThings: '');
      expect(state.status, HubStatus.disconnected);
      expect(mem.data.containsKey(CredentialsStore.kSmartThings), isFalse);
    });

    test('switching to hub mode and back keeps both working', () async {
      registerSt();
      final hubApi = FakeHubApi();
      final s2 = HubState(
        settings: settings,
        apiFactory: (_) => hubApi,
        credentials: CredentialsStore(mem),
        directFactory: (store) => defaultDirectBackendFactory(store, client: cloud.client, pollInterval: null),
      );
      await s2.saveTokens(smartThings: 'pat');
      expect(s2.mode, BackendKind.directCloud);
      await settings.saveHub(const HubConfig(host: '10.0.0.2'));
      await s2.selectMode(BackendKind.hub);
      expect(s2.mode, BackendKind.hub);
      expect(s2.api, isNotNull);
      expect(s2.devices, hasLength(6)); // fake hub fixture
      await s2.selectMode(BackendKind.directCloud);
      expect(s2.mode, BackendKind.directCloud);
      expect(s2.devices.map((d) => d.adapter).toSet(), {'smartthings'});
      expect(settings.mode, BackendKind.directCloud);
    });
  });
}
