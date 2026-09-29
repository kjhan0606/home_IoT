import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homeiot/api/hub_discovery.dart';
import 'package:homeiot/app.dart';
import 'package:homeiot/backend/device_backend.dart';
import 'package:homeiot/backend/direct/direct_factory.dart';
import 'package:homeiot/models/hub_config.dart';
import 'package:homeiot/screens/device_detail_screen.dart';
import 'package:homeiot/screens/settings_screen.dart';
import 'package:homeiot/state/credentials_store.dart';
import 'package:homeiot/state/hub_state.dart';
import 'package:homeiot/state/settings_store.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fake_hub_api.dart';
import 'fixtures.dart';

class _NoDiscovery implements HubDiscovery {
  @override
  bool get supported => false;
  @override
  Stream<List<HubConfig>> discover() => const Stream.empty();
  @override
  Future<void> stop() async {}
}

Future<(HubState, MockCloud, MemorySecretStore)> pump(
  WidgetTester tester, {
  Widget? home,
  Map<String, String> secrets = const {},
  bool start = false,
}) async {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({});
  final cloud = MockCloud();
  cloud.on('GET', '$stBase/devices', {
    'items': [stTv, stWasher],
  });
  cloud.on('GET', '$stBase/devices/tv-1/status', stTvStatus);
  cloud.on('GET', '$stBase/devices/washer-1/status', stWasherStatus(remote: 'false'));
  final mem = MemorySecretStore()..data.addAll(secrets);
  final hub = HubState(
    settings: SettingsStore(await SharedPreferences.getInstance()),
    apiFactory: (_) => FakeHubApi(),
    credentials: CredentialsStore(mem),
    directFactory: (store) =>
        defaultDirectBackendFactory(store, client: cloud.client, pollInterval: null, settleDelay: Duration.zero),
  );
  if (start) await hub.start();
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: hub),
        Provider<HubDiscovery>.value(value: _NoDiscovery()),
      ],
      child: home == null ? const HomeIotApp() : MaterialApp(theme: HomeIotApp.theme(Brightness.light), home: home),
    ),
  );
  await tester.pumpAndSettle();
  return (hub, cloud, mem);
}

void main() {
  testWidgets('first run shows onboarding with direct mode selected and token fields', (tester) async {
    await pump(tester);
    expect(find.text('시작하기'), findsOneWidget);
    expect(find.byKey(const Key('mode-picker')), findsOneWidget);
    expect(find.byKey(const Key('st-token')), findsOneWidget);
    expect(find.textContaining('24시간'), findsWidgets); // PAT expiry is explained up front
    expect(find.byKey(const Key('lg-country')), findsOneWidget);
  });

  testWidgets('entering tokens saves them to secure storage and shows the device list', (tester) async {
    final (hub, cloud, mem) = await pump(tester);
    await tester.enterText(find.byKey(const Key('st-token')), 'my-pat');
    final save = find.byKey(const Key('save-tokens'));
    await tester.ensureVisible(save);
    await tester.pumpAndSettle();
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(mem.data[CredentialsStore.kSmartThings], 'my-pat');
    expect(hub.status, HubStatus.connected);
    expect(find.text('홈 IoT'), findsOneWidget);
    expect(find.text('[TV] Samsung 8 Series (55)'), findsOneWidget);
    expect(find.textContaining('직접 연결'), findsWidgets);
    expect(cloud.calls.first.headers['Authorization'], 'Bearer my-pat');
  });

  testWidgets('invalid LG country code is rejected before saving', (tester) async {
    final (_, _, mem) = await pump(tester);
    await tester.enterText(find.byKey(const Key('lg-token')), 'lg-pat');
    await tester.enterText(find.byKey(const Key('lg-country')), '1');
    final save = find.byKey(const Key('save-tokens'));
    await tester.ensureVisible(save);
    await tester.pumpAndSettle();
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(find.textContaining('국가 코드'), findsWidgets);
    expect(mem.data, isEmpty);
  });

  testWidgets('device list is capability-driven: TV toggle and washer remote-off banner work in direct mode', (
    tester,
  ) async {
    final (hub, cloud, _) = await pump(tester, secrets: {CredentialsStore.kSmartThings: 'pat'}, start: true);
    expect(find.text('TV  1'), findsOneWidget);
    expect(find.text('세탁기  1'), findsOneWidget);
    cloud.on('POST', '$stBase/devices/tv-1/commands', {'results': []});
    await tester.tap(find.byKey(const Key('power-smartthings:tv-1')));
    await tester.pumpAndSettle();
    expect(cloud.posts.single.json['commands'][0]['capability'], 'switch');
    expect(hub.devices, hasLength(2));

    await tester.pumpWidget(
      MultiProvider(
        providers: [ChangeNotifierProvider.value(value: hub)],
        child: MaterialApp(
          theme: HomeIotApp.theme(Brightness.light),
          home: const DeviceDetailScreen(deviceId: 'smartthings:washer-1'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('remote-start-banner')), findsOneWidget);
  });

  testWidgets('expired token: banner with a shortcut to token settings', (tester) async {
    final (_, cloud, _) = await pump(tester, secrets: {CredentialsStore.kSmartThings: 'old'}, start: false);
    cloud.on('GET', '$stBase/devices', {'error': 'invalid_token'}, status: 401);
    final hub = tester.element(find.byType(Scaffold).first).read<HubState>();
    await hub.start();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('warning-smartthings')), findsOneWidget);
    expect(find.textContaining('24시간'), findsWidgets);
    await tester.tap(find.text('토큰 설정'));
    await tester.pumpAndSettle();
    expect(find.text('클라우드 계정'), findsOneWidget);
  });

  testWidgets('settings in direct mode: cloud accounts + mode switch, no hub-only sections', (tester) async {
    final (_, _, _) = await pump(
      tester,
      secrets: {CredentialsStore.kSmartThings: 'pat'},
      start: true,
      home: const SettingsScreen(),
    );
    expect(find.text('클라우드 계정'), findsOneWidget);
    expect(find.byKey(const Key('cloud-smartthings')), findsOneWidget);
    expect(find.byKey(const Key('edit-tokens')), findsOneWidget);
    expect(find.text('허브 변경'), findsNothing);
    expect(find.text('Roborock 계정'), findsNothing);
    expect(find.byKey(const Key('mode-picker')), findsOneWidget);
  });

  testWidgets('hub mode still shows the hub connect screen when no hub is remembered', (tester) async {
    SharedPreferences.setMockInitialValues({'backendMode': 'hub'});
    final hub = HubState(
      settings: SettingsStore(await SharedPreferences.getInstance()),
      apiFactory: (_) => FakeHubApi(),
    );
    expect(hub.settings.mode, BackendKind.hub);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: hub),
          Provider<HubDiscovery>.value(value: _NoDiscovery()),
        ],
        child: const HomeIotApp(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('허브 연결'), findsOneWidget);
  });
}
