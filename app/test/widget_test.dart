import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homeiot/api/hub_api.dart';
import 'package:homeiot/api/hub_discovery.dart';
import 'package:homeiot/app.dart';
import 'package:homeiot/l10n/ko.dart';
import 'package:homeiot/models/hub_config.dart';
import 'package:homeiot/screens/device_detail_screen.dart';
import 'package:homeiot/screens/settings_screen.dart';
import 'package:homeiot/screens/vacuum_map_screen.dart';
import 'package:homeiot/state/hub_state.dart';
import 'package:homeiot/state/settings_store.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_hub_api.dart';

class FakeDiscovery implements HubDiscovery {
  @override
  bool get supported => true;
  @override
  Stream<List<HubConfig>> discover() => Stream.value(const [HubConfig(host: '192.168.0.77', name: 'LivingRoomHub')]);
  @override
  Future<void> stop() async {}
}

Future<(HubState, FakeHubApi)> pumpApp(
  WidgetTester tester, {
  Widget? home,
  bool connect = true,
  Map<String, Object> prefs = const {},
}) async {
  tester.view.physicalSize = const Size(1170, 2532); // iPhone-ish
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues(prefs);
  final api = FakeHubApi();
  final hub = HubState(settings: SettingsStore(await SharedPreferences.getInstance()), apiFactory: (_) => api);
  if (connect) await hub.connect(const HubConfig(host: '192.168.0.10'));
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: hub),
        Provider<HubDiscovery>.value(value: FakeDiscovery()),
      ],
      child: home == null ? const HomeIotApp() : MaterialApp(theme: HomeIotApp.theme(Brightness.light), home: home),
    ),
  );
  await tester.pumpAndSettle();
  return (hub, api);
}

Future<void> scrollTo(WidgetTester tester, Finder f) async {
  await tester.scrollUntilVisible(f, 200, scrollable: find.byType(Scrollable).first);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('connect screen: discovered hub + manual entry', (tester) async {
    final (hub, api) = await pumpApp(tester, connect: false, prefs: {'backendMode': 'hub'});
    expect(find.text('허브 연결'), findsOneWidget);
    expect(find.text('LivingRoomHub'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('hub-address')), '192.168.0.10:8099');
    await tester.tap(find.byKey(const Key('connect')));
    await tester.pumpAndSettle();
    expect(hub.status, HubStatus.connected);
    expect(api.calls, contains('health'));
    expect(find.text(Ko.appTitle), findsOneWidget); // device list
  });

  testWidgets('device list groups by kind, marks example data, toggles power', (tester) async {
    final (_, api) = await pumpApp(tester);
    expect(find.textContaining('예시 데이터'), findsOneWidget);
    expect(find.text('TV  1'), findsOneWidget);
    expect(find.text('로봇청소기  1'), findsOneWidget);
    await tester.tap(find.byKey(const Key('power-demo:light')));
    await tester.pumpAndSettle();
    expect(api.commands.single.toString(), 'demo:light power.turnOn {}');
    // room grouping
    await tester.tap(find.text('방별'));
    await tester.pumpAndSettle();
    expect(find.text('거실  2'), findsOneWidget);
    // scan
    await tester.tap(find.byKey(const Key('scan')));
    await tester.pumpAndSettle();
    expect(api.calls, contains('scan'));
  });

  testWidgets('TV remote renders from capabilities and sends commands', (tester) async {
    final (_, api) = await pumpApp(tester, home: const DeviceDetailScreen(deviceId: 'demo:tv'));
    await tester.tap(find.byTooltip('볼륨 높이기'));
    await tester.pumpAndSettle();
    expect(api.commands.last.toString(), 'demo:tv volume.volumeUp {}');
    expect(find.byType(Slider), findsOneWidget); // setLevel supported
    await scrollTo(tester, find.text('HDMI1'));
    await tester.tap(find.text('HDMI1'));
    await tester.pumpAndSettle();
    expect(api.commands.last.toString(), 'demo:tv mediaInput.select {source: HDMI1}');
    await scrollTo(tester, find.byTooltip('일시정지'));
    await tester.tap(find.byTooltip('일시정지'));
    await tester.pumpAndSettle();
    expect(api.commands.last.action, 'pause');
    await scrollTo(tester, find.text('Netflix'));
    await tester.tap(find.text('Netflix'));
    await tester.pumpAndSettle();
    expect(api.commands.last.params, {'app': 'Netflix'});
  });

  testWidgets('washer: remote-start banner and Korean 403 message', (tester) async {
    final (_, api) = await pumpApp(tester, home: const DeviceDetailScreen(deviceId: 'demo:washer'));
    api.failures['washer.start'] = const HubApiException(403, 'Remote control is disabled');
    expect(find.byKey(const Key('remote-start-banner')), findsOneWidget);
    expect(find.text('헹굼'), findsOneWidget);
    expect(find.text('42분'), findsOneWidget);
    await tester.tap(find.text('시작'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.descendant(of: find.byType(SnackBar), matching: find.text(Ko.remoteStartHelp)), findsOneWidget);
  });

  testWidgets('fridge: setpoints, doors, rapid freeze', (tester) async {
    final (_, api) = await pumpApp(tester, home: const DeviceDetailScreen(deviceId: 'demo:fridge'));
    expect(find.text('-19°C'), findsOneWidget);
    expect(find.text('3.4°C'), findsNothing); // measured shown as "현재 3.4°C"
    expect(find.text('현재 3.4°C'), findsOneWidget);
    await tester.tap(find.byTooltip('냉장실 설정 온도 높이기'));
    await tester.pumpAndSettle();
    expect(api.commands.last.toString(), 'demo:fridge refrigeration.setFridgeSetpoint {temperature: 4}');
    await tester.tap(find.text('급냉'));
    await tester.pumpAndSettle();
    expect(api.commands.last.toString(), 'demo:fridge refrigeration.setRapidCooling {enabled: true}');
  });

  testWidgets('vacuum detail: controls, fan, mop, consumable reset', (tester) async {
    final (_, api) = await pumpApp(tester, home: const DeviceDetailScreen(deviceId: 'demo:vacuum'));
    expect(find.text('충전대 대기'), findsOneWidget);
    expect(find.text(' 87%'), findsOneWidget);
    await tester.tap(find.text('청소 시작'));
    await tester.pumpAndSettle();
    expect(api.commands.last.toString(), 'demo:vacuum vacuum.start {}');
    await scrollTo(tester, find.text('터보'));
    await tester.tap(find.text('터보'));
    await tester.pumpAndSettle();
    expect(api.commands.last.toString(), 'demo:vacuum fanSpeed.setLevel {level: turbo}');
    await scrollTo(tester, find.text('딥'));
    await tester.tap(find.text('딥'));
    await tester.pumpAndSettle();
    expect(api.commands.last.toString(), 'demo:vacuum mopping.setMopMode {mode: deep}');
    await scrollTo(tester, find.byTooltip('필터 초기화'));
    await tester.tap(find.byTooltip('필터 초기화'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '초기화'));
    await tester.pumpAndSettle();
    expect(api.commands.last.toString(), 'demo:vacuum consumables.reset {id: filter}');
    expect(find.text('42.5 m²'), findsOneWidget);
  });

  group('vacuum map', () {
    Future<(FakeHubApi, Rect)> openMap(WidgetTester tester) async {
      final (_, api) = await pumpApp(tester, home: const VacuumMapScreen(deviceId: 'demo:vacuum'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();
      return (api, tester.getRect(find.byKey(const Key('map-canvas'))));
    }

    Offset at(Rect canvas, double px, double py) => canvas.topLeft + Offset(px, py) * (canvas.width / 600);

    testWidgets('tap rooms to select and clean with repeat', (tester) async {
      final (api, canvas) = await openMap(tester);
      expect(find.text(Ko.example), findsOneWidget);
      await tester.tapAt(at(canvas, 100, 100)); // 거실
      await tester.pump(const Duration(milliseconds: 400)); // wait out double-tap/long-press disambiguation
      await tester.tapAt(at(canvas, 500, 500)); // 침실
      await tester.pumpAndSettle();
      expect(find.text('선택: 거실, 침실'), findsOneWidget);
      await tester.tap(find.text('2회'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('clean-selection')));
      await tester.pumpAndSettle();
      final c = api.commands.last;
      expect('${c.capability}.${c.action}', 'roomCleaning.cleanRooms');
      expect(c.params, {
        'roomIds': ['16', '18'],
        'repeat': 2,
      });
    });

    testWidgets('draw a zone -> map coordinates', (tester) async {
      final (api, canvas) = await openMap(tester);
      await tester.tap(find.text('구역 그리기'));
      await tester.pumpAndSettle();
      final g = await tester.startGesture(at(canvas, 100, 100));
      await g.moveBy(const Offset(10, 10));
      await g.moveTo(at(canvas, 200, 150));
      await g.up();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('clean-selection')));
      await tester.pumpAndSettle();
      final c = api.commands.last;
      expect('${c.capability}.${c.action}', 'zoneCleaning.cleanZones');
      final zone = (c.params['zones'] as List).single as List<int>;
      // image (100,100)-(200,150) -> map x 22000..24000, y 27000..28000 (±1px slop)
      expect(zone[0], closeTo(22000, 60));
      expect(zone[1], closeTo(27000, 60));
      expect(zone[2], closeTo(24000, 60));
      expect(zone[3], closeTo(28000, 60));
    });

    testWidgets('long-press sends goTo with transformed coordinates', (tester) async {
      final (api, canvas) = await openMap(tester);
      await tester.longPressAt(at(canvas, 300, 300));
      await tester.pumpAndSettle();
      expect(find.text('이 위치로 이동할까요?'), findsOneWidget);
      await tester.tap(find.text('이동'));
      await tester.pumpAndSettle();
      final c = api.commands.last;
      expect('${c.capability}.${c.action}', 'goTo.goTo');
      expect(c.params['x'] as int, closeTo(26000, 30));
      expect(c.params['y'] as int, closeTo(24000, 30));
    });
  });

  testWidgets('generic fallback: light brightness/color, lock', (tester) async {
    final (_, api) = await pumpApp(tester, home: const DeviceDetailScreen(deviceId: 'demo:lock'));
    expect(find.text('잠김'), findsOneWidget);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(api.commands.last.toString(), 'demo:lock lock.unlock {}');
    expect(find.text('64%'), findsOneWidget); // sensor readout battery
  });

  testWidgets('settings: integrations + Roborock code login flow + unlink', (tester) async {
    final (_, api) = await pumpApp(tester, home: const SettingsScreen());
    expect(find.text('Samsung SmartThings (cloud)'), findsOneWidget);
    expect(find.textContaining('SMARTTHINGS_TOKEN'), findsOneWidget);
    await scrollTo(tester, find.byKey(const Key('roborock-email')));
    await tester.enterText(find.byKey(const Key('roborock-email')), 'me@example.com');
    await tester.tap(find.byKey(const Key('roborock-request-code')));
    await tester.pumpAndSettle();
    expect(api.calls, contains('request-code:me@example.com'));
    await scrollTo(tester, find.byKey(const Key('roborock-code')));
    await tester.enterText(find.byKey(const Key('roborock-code')), '123456');
    await scrollTo(tester, find.byKey(const Key('roborock-login')));
    await tester.tap(find.byKey(const Key('roborock-login')));
    await tester.pumpAndSettle();
    expect(api.calls, contains('login:me@example.com:123456'));
    expect(api.calls, contains('scan'));
    await scrollTo(tester, find.textContaining('연결됨'));
    expect(find.textContaining('j***@example.com'), findsOneWidget);
    await scrollTo(tester, find.byKey(const Key('roborock-unlink')));
    await tester.tap(find.byKey(const Key('roborock-unlink')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '해제'));
    await tester.pumpAndSettle();
    expect(api.calls, contains('unlink'));
  });

  testWidgets('dark theme renders', (tester) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await pumpApp(tester);
    final ctx = tester.element(find.text(Ko.appTitle));
    expect(Theme.of(ctx).brightness, Brightness.dark);
  });
}
