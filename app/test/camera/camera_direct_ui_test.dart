import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homeiot/api/hub_discovery.dart';
import 'package:homeiot/app.dart';
import 'package:homeiot/backend/device_backend.dart';
import 'package:homeiot/backend/direct/camera_provider.dart';
import 'package:homeiot/backend/direct/direct_cloud_backend.dart';
import 'package:homeiot/camera/camera_store.dart';
import 'package:homeiot/models/hub_config.dart';
import 'package:homeiot/state/credentials_store.dart';
import 'package:homeiot/state/hub_state.dart';
import 'package:homeiot/state/settings_store.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fake_hub_api.dart';

class _NoDiscovery implements HubDiscovery {
  @override
  bool get supported => false;
  @override
  Stream<List<HubConfig>> discover() => const Stream.empty();
  @override
  Future<void> stop() async {}
}

Future<DeviceBackend> factory(CredentialsStore store) async => DirectCloudBackend(
  pollInterval: null,
  settleDelay: Duration.zero,
  providers: [
    DirectCameraProvider(CameraStore(store.secrets), client: MockClient((_) async => http.Response('', 404)), discover: () async => [], probe: (h, p) async => false),
  ],
);

void main() {
  testWidgets('direct mode: camera-only onboarding -> demo cameras -> live view, PTZ, persistence', (tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final mem = MemorySecretStore();
    final prefs = await SharedPreferences.getInstance();
    final hub = HubState(
      settings: SettingsStore(prefs),
      apiFactory: (_) => FakeHubApi(),
      credentials: CredentialsStore(mem),
      directFactory: factory,
    );
    // the demo pictures are bundled assets (assets/demo/*.jpg) and load through rootBundle
    await tester.pumpWidget(
      MultiProvider(
        providers: [ChangeNotifierProvider.value(value: hub), Provider<HubDiscovery>.value(value: _NoDiscovery())],
        child: const HomeIotApp(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.byKey(const Key('camera-only')), 300, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.byKey(const Key('camera-only')));
    await tester.pumpAndSettle();
    expect(hub.status, HubStatus.connected);
    expect(hub.devices, isEmpty);

    await tester.tap(find.byKey(const Key('add-camera')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('주소 입력'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.byKey(const Key('add-demo-living')), 300, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.byKey(const Key('add-demo-living')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('add-camera')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('주소 입력'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.byKey(const Key('add-demo-door')), 300, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.byKey(const Key('add-demo-door')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('camera-grid')), findsOneWidget);
    expect(hub.devices.map((d) => d.kind), ['camera', 'camera']);
    expect(mem.data.keys, contains(CameraStore.key));

    final living = hub.devices.firstWhere((d) => d.has('ptz'));
    await tester.tap(find.byKey(Key('device-${living.id}')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('camera-frame')), findsOneWidget);
    final before = tester.widget<Image>(find.byKey(const Key('camera-frame'))).image;
    final g = await tester.startGesture(tester.getCenter(find.byKey(const Key('ptz-right'))));
    await tester.pump();
    await g.up();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('refresh-snapshot')));
    await tester.pumpAndSettle();
    final after = tester.widget<Image>(find.byKey(const Key('camera-frame'))).image;
    expect(after, isNot(before), reason: 'PTZ changed the demo picture');

    // a fresh app start (new HubState over the same secure storage) still has both cameras
    final hub2 = HubState(
      settings: SettingsStore(prefs),
      apiFactory: (_) => FakeHubApi(),
      credentials: CredentialsStore(mem),
      directFactory: factory,
    );
    await hub2.start();
    expect(hub2.status, HubStatus.connected);
    expect(hub2.devices, hasLength(2));
  });

  test('bundled demo pictures exist', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    for (final n in ['demo_door', for (var c = 0; c < 3; c++) for (var r = 0; r < 3; r++) 'demo_living_${c}_$r']) {
      final d = await rootBundle.load('assets/demo/$n.jpg');
      expect(d.lengthInBytes, greaterThan(1000), reason: n);
    }
  });
}
